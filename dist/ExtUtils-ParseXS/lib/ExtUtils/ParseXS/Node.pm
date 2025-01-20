package ExtUtils::ParseXS::Node;
use strict;
use warnings;

our $VERSION = '3.57';

=head1 NAME

ExtUtils::ParseXS::Node - Classes for nodes of an ExtUtils::ParseXS AST

=head1 SYNOPSIS

XXX TBC

=head1 DESCRIPTION

XXX Sept 2024: this is Work In Progress. This API is currently private and
subject to change. Most of ParseXS doesn't use an AST, and instead
maintains just enough state to emit code as it parses. This module
represents the start of an effort to make it use an AST instead.

An C<ExtUtils::ParseXS::Node> class, and its various subclasses, hold the
state for the nodes of an Abstract Syntax Tree (AST), which represents the
parsed state of an XS file.

Each node is basically a hash of fields. Which field names are legal
varies by the node type. The hash keys and values can be accessed
directly: there are no getter/setter methods.

=cut


# ======================================================================

package ExtUtils::ParseXS::Node;

# Base class for all the other node types.
#
# The 'use fields' enables compile-time or run-time errors if code
# attempts to use a key which isn't listed here.

my $USING_FIELDS;

BEGIN {
    our @FIELDS = (
        # Currently there are no node fields common to all node types
    );

    # do 'use fields', except: fields needs Hash::Util which is XS, which
    # needs us. So only 'use fields' on systems where Hash::Util has already
    # been built.
    if (eval 'require Hash::Util; 1;') {
        require fields;
        $USING_FIELDS = 1;
        fields->import(@FIELDS);
    }
}


# new(): takes one optional arg, $args, which is a hash ref of key/value
# pairs to initialise the object with.

sub new {
    my ($class, $args) = @_;
    $args = {} unless defined $args;

    my ExtUtils::ParseXS::Node $self;
    if ($USING_FIELDS) {
        $self = fields::new($class);
        %$self = %$args;
    }
    else {
        $self = bless { %$args } => $class;
    }
    return $self;
}


# ======================================================================

package ExtUtils::ParseXS::Node::Param;

# Node subclass which holds the state of one XSUB parameter, based on the
# XSUB's signature and/or an INPUT line.

BEGIN {
    our @ISA = qw(ExtUtils::ParseXS::Node);

    our @FIELDS = (
        @ExtUtils::ParseXS::Node::FIELDS,

        # values derived from the XSUB's signature
        'in_out',    # The IN/OUT/OUTLIST etc value (if any)
        'var',       # the name of the parameter
        'arg_num',   # The arg number (starting at 1) mapped to this param
        'default',   # default value (if any)
        'default_usage', # how to report default value in "usage:..." error
        'is_ansi',   # param's type was specified in signature
        'is_length', # param is declared as 'length(foo)' in signature
        'len_name' , # the 'foo' in 'length(foo)' in signature
        'is_synthetic',# var like 'THIS' - we pretend it was in the sig

        # values derived from both the XSUB's signature and/or INPUT line
        'type',      # The C type of the parameter
        'no_init',   # don't initialise the parameter

        # values derived from the XSUB's INPUT line
        'init_op',   # initialisation type: one of =/+/;
        'init',      # initialisation template code
        'is_addr',   # INPUT var declared as '&foo'
        'is_alien',  # var declared in INPUT line, but not in signature
        'in_input',  # the parameter has appeared in an INPUT statement

        # values derived from the XSUB's OUTPUT line
        'in_output',   # the parameter has appeared in an OUTPUT statement
        'do_setmagic', # 'SETMAGIC: ENABLE' was active for this parameter
        'output_code', # the optional setting-code for this parameter

        # derived values calculated later
        'defer',     # deferred initialisation template code
        'proto',     # overridden prototype char(s) (if any) from typemap
    );

    fields->import(@FIELDS) if $USING_FIELDS;
}



# check(): for a parsed INPUT line and/or typed parameter in a signature,
# update some global state and do some checks
#
# Return true if checks pass.

sub check {
    my ExtUtils::ParseXS::Node::Param $self = shift;
    my ExtUtils::ParseXS              $pxs  = shift;
  
    my $type = $self->{type};

    # Get the overridden prototype character, if any, associated with the
    # typemap entry for this var's type.
    # Note that something with a provisional type such as THIS can get
    # the type changed later. It is important to update each time.
    # It also can't be looked up only at BOOT code emitting time, because
    # potentiall, the typmap may been bee updated last in the XS file
    # after the XSUB was parsed.
    if ($self->{arg_num}) {
        my $typemap = $pxs->{typemaps_object}->get_typemap(ctype => $type);
        my $p = $typemap && $typemap->proto;
        $self->{proto} = $p if defined $p && length $p;
    }
  
    return 1;
}


# $self->as_code()
# Emit the param object as C code

sub as_code {
    my ExtUtils::ParseXS::Node::Param $self = shift;
    my ExtUtils::ParseXS              $pxs  = shift;
  
    my ($type, $arg_num, $var, $init, $no_init, $defer, $default)
        = @{$self}{qw(type arg_num var init no_init defer default)};
  
    my $arg = $pxs->ST($arg_num);
  
    if ($self->{is_length}) {
        # Process length(foo) parameter.
        # Basically for something like foo(char *s, int length(s)),
        # create *two* local C vars: one with STRLEN type, and one with the
        # type specified in the signature. Eventually, generate code looking
        # something like:
        #   STRLEN  STRLEN_length_of_s;
        #   int     XSauto_length_of_s;
        #   char *s = (char *)SvPV(ST(0), STRLEN_length_of_s);
        #   XSauto_length_of_s = STRLEN_length_of_s;
        #   RETVAL = foo(s, XSauto_length_of_s);
        #
        # Note that the SvPV() code line is generated via a separate call to
        # this sub with s as the var (as opposed to *this* call, which is
        # handling length(s)), by overriding the normal T_PV typemap (which
        # uses PV_nolen()).
  
        my $name = $self->{len_name};
  
        print "\tSTRLEN\tSTRLEN_length_of_$name;\n";
        # defer this line until after all the other declarations
        $pxs->{xsub_deferred_code_lines} .=
                "\n\tXSauto_length_of_$name = STRLEN_length_of_$name;\n";
  
        # this var will be declared using the normal typemap mechanism below
        $var = "XSauto_length_of_$name";
    }
  
    # Emit the variable's type and name.
    #
    # Includes special handling for function pointer types. An INPUT line
    # always has the C type followed by the variable name. The C code
    # which is emitted normally follows the same pattern. However for
    # function pointers, the code is different: the variable name has to
    # be embedded *within* the type. For example, these two INPUT lines:
    #
    #    char *        s
    #    int (*)(int)  fn_ptr
    #
    # cause the following lines of C to be emitted;
    #
    #    char *              s = [something from a typemap]
    #    int (* fn_ptr)(int)   = [something from a typemap]
    #
    # So handle specially the specific case of a type containing '(*)' by
    # embedding the variable name *within* rather than *after* the type.
  
  
    if ($type =~ / \( \s* \* \s* \) /x) {
        # for a fn ptr type, embed the var name in the type declaration
        print "\t" . $pxs->map_type($type, $var);
    }
    else {
        print "\t",
                    ((defined($pxs->{xsub_class}) && $var eq 'CLASS')
                        ? $type
                        : $pxs->map_type($type, undef)),
              "\t$var";
    }
  
    # whitespace-tidy the type
    $type = ExtUtils::Typemaps::tidy_type($type);
  
    # Specify the environment for when the initialiser template is evaled.
    # Only the common ones are specified here. Other fields may be added
    # later.
    my $eval_vars = {
        type          => $type,
        var           => $var,
        num           => $arg_num,
        arg           => $arg,
    };
  
    # The type looked up in the eval is Foo__Bar rather than Foo::Bar
    $eval_vars->{type} =~ tr/:/_/
        unless $pxs->{config_RetainCplusplusHierarchicalTypes};
  
    my $init_template;
  
    if (defined $init) {
        # Use the supplied code template rather than getting it from the
        # typemap
  
        $pxs->death(
                "Internal error: ExtUtils::ParseXS::Node::Param::as_code(): "
              . "both init and no_init supplied")
            if $no_init;
  
        $eval_vars->{init} = $init;
        $init_template = "\$var = $init";
    }
    elsif ($no_init) {
        # don't add initialiser
        $init_template = "";
    }
    else {
        # Get the initialiser template from the typemap
  
        my $typemaps = $pxs->{typemaps_object};
  
        # Normalised type ('Foo *' becomes 'FooPtr): one of the valid vars
        # which can appear within a typemap template.
        (my $ntype = $type) =~ s/\s*\*/Ptr/g;
  
        # $subtype is really just for the T_ARRAY / DO_ARRAY_ELEM code below,
        # where it's the type of each array element. But it's also passed to
        # the typemap template (although undocumented and virtually unused).
        (my $subtype = $ntype) =~ s/(?:Array)?(?:Ptr)?$//;
  
        # look up the TYPEMAP entry for this C type and grab the corresponding
        # XS type name (e.g. $type of 'char *'  gives $xstype of 'T_PV'
        my $typemap = $typemaps->get_typemap(ctype => $type);
        if (not $typemap) {
            $pxs->report_typemap_failure($typemaps, $type);
            return;
        }
        my $xstype = $typemap->xstype;
  
        # An optimisation: for the typemaps which check that the dereferenced
        # item is blessed into the right class, skip the test for DESTROY()
        # methods, as more or less by definition, DESTROY() will be called
        # on an object of the right class. Basically, for T_foo_OBJ, use
        # T_foo_REF instead. T_REF_IV_PTR was added in v5.22.0.
        $xstype =~ s/OBJ$/REF/ || $xstype =~ s/^T_REF_IV_PTR$/T_PTRREF/
            if $pxs->{xsub_func_name} =~ /DESTROY$/;
  
        # For a string-ish parameter foo, if length(foo) was also declared
        # as a pseudo-parameter, then override the normal typedef - which
        # would emit SvPV_nolen(...) - and instead, emit SvPV(...,
        # STRLEN_length_of_foo)
        if (    $xstype eq 'T_PV'
                and exists $pxs->{xsub_sig}{names}{"length($var)"})
        {
            print " = ($type)SvPV($arg, STRLEN_length_of_$var);\n";
            die "default value not supported with length(NAME) supplied"
                if defined $default;
            return;
        }
  
        # Get the ExtUtils::Typemaps::InputMap object associated with the
        # xstype. This contains the template of the code to be embedded,
        # e.g. 'SvPV_nolen($arg)'
        my $inputmap = $typemaps->get_inputmap(xstype => $xstype);
        if (not defined $inputmap) {
            $pxs->blurt("Error: No INPUT definition for type '$type', typekind '$xstype' found");
            return;
        }
  
        # Get the text of the template, with a few transformations to make it
        # work better with fussy C compilers. In particular, strip trailing
        # semicolons and remove any leading white space before a '#'.
        my $expr = $inputmap->cleaned_code;
  
        my $argoff = $arg_num - 1;
  
        # Process DO_ARRAY_ELEM. This is an undocumented hack that makes the
        # horrible T_ARRAY typemap work. "DO_ARRAY_ELEM" appears as a token
        # in the INPUT and OUTPUT code for for T_ARRAY, within a "for each
        # element" loop, and the purpose of this branch is to substitute the
        # token for some real code which will process each element, based
        # on the type of the array elements (the $subtype).
        #
        # Note: This gruesome bit either needs heavy rethinking or
        # documentation. I vote for the former. --Steffen, 2011
        # Seconded, DAPM 2024.
        if ($expr =~ /\bDO_ARRAY_ELEM\b/) {
            my $subtypemap  = $typemaps->get_typemap(ctype => $subtype);
            if (not $subtypemap) {
                $pxs->report_typemap_failure($typemaps, $subtype);
                return;
            }
  
            my $subinputmap =
                $typemaps->get_inputmap(xstype => $subtypemap->xstype);
            if (not $subinputmap) {
                $pxs->blurt("Error: No INPUT definition for type '$subtype',
                            typekind '" . $subtypemap->xstype . "' found");
                return;
            }
  
            my $subexpr = $subinputmap->cleaned_code;
            $subexpr =~ s/\$type/\$subtype/g;
            $subexpr =~ s/ntype/subtype/g;
            $subexpr =~ s/\$arg/ST(ix_$var)/g;
            $subexpr =~ s/\n\t/\n\t\t/g;
            $subexpr =~ s/is not of (.*\")/[arg %d] is not of $1, ix_$var + 1/g;
            $subexpr =~ s/\$var/${var}\[ix_$var - $argoff]/;
            $expr =~ s/\bDO_ARRAY_ELEM\b/$subexpr/;
        }
  
        if ($expr =~ m#/\*.*scope.*\*/#i) {  # "scope" in C comments
            $pxs->{xsub_SCOPE_enabled} = 1;
        }
  
        # Specify additional environment for when a template derived from a
        # *typemap* is evalled.
        @$eval_vars{qw(ntype subtype argoff)} = ($ntype, $subtype, $argoff);
        $init_template = $expr;
    }
  
    # Now finally, emit the actual variable declaration and initialisation
    # line(s). The variable type and name will already have been emitted.
  
    my $init_code =
        length $init_template
            ? $pxs->eval_input_typemap_code("qq\a$init_template\a", $eval_vars)
            : "";
  
  
    if (defined $default
        # XXX for now, for backcompat, ignore default if the
        # param has a typemap override
        && !(defined $init)
        # XXX for now, for backcompat, ignore default if the
        # param wouldn't otherwise get initialised
        && !$no_init
    ) {
        # Has a default value. Just terminate the variable declaration, and
        # defer the initialisation.
  
        print ";\n";
  
        # indent the code 1 step further
        $init_code =~ s/(\t+)/$1    /g;
        $init_code =~ s/        /\t/g;
  
        if ($default eq 'NO_INIT') {
            # for foo(a, b = NO_INIT), add code to initialise later only if
            # an arg was supplied.
            $pxs->{xsub_deferred_code_lines}
                .= sprintf "\n\tif (items >= %d) {\n%s;\n\t}\n",
                           $arg_num, $init_code;
        }
        else {
            # for foo(a, b = default), add code to initialise later to either
            # the arg or default value
            my $else = ($init_code =~ /\S/) ? "\telse {\n$init_code;\n\t}\n" : "";
  
            $default =~ s/"/\\"/g; # escape double quotes
            $pxs->{xsub_deferred_code_lines}
                .= sprintf "\n\tif (items < %d)\n\t    %s = %s;\n%s",
                        $arg_num,
                        $var,
                        $pxs->eval_input_typemap_code("qq\a$default\a",
                                                       $eval_vars),
                        $else;
        }
    }
    elsif ($pxs->{xsub_SCOPE_enabled} or $init_code !~ /^\s*\Q$var\E =/) {
        # The template is likely a full block rather than a '$var = ...'
        # expression. Just terminate the variable declaration, and defer the
        # initialisation.
        # Note that /\Q$var\E/ matches the string containing whatever $var
        # was expanded to in the eval.
  
        print ";\n";
  
        $pxs->{xsub_deferred_code_lines} .= sprintf "\n%s;\n", $init_code
            if $init_code =~ /\S/;
    }
    else {
        # The template starts with '$var = ...'. The variable name has already
        # been emitted, so remove it from the typemap before evalling it,
  
        $init_code =~ s/^\s*\Q$var\E(\s*=\s*)/$1/
            or $pxs->death("panic: typemap doesn't start with '\$var='\n");
  
        printf "%s;\n", $init_code;
    }
  
    if (defined $defer) {
        $pxs->{xsub_deferred_code_lines}
            .= $pxs->eval_input_typemap_code("qq\a$defer\a", $eval_vars) . "\n";
    }
}


# ======================================================================

package ExtUtils::ParseXS::Node::Sig;

# Node subclass which holds the state of an XSUB's signature, based on the
# XSUB's actual signature plus any INPUT lines. It is a mainly a list of
# Node::Param children.

BEGIN {
    our @ISA = qw(ExtUtils::ParseXS::Node);

    our @FIELDS = (
        @ExtUtils::ParseXS::Node::FIELDS,
        'orig_params',   # Array ref of Node::Param objects representing
                         # the original (as parsed) parameters of this XSUB

        'params',        # Array ref of Node::Param objects representing
                         # the current parameters of this XSUB - this
                         # is orig_params plus any updated fields from
                         # processing INPUT and OUTPUT lines. Note that
                         # with multiple CASE: blocks, there can be
                         # multiple sets of INPUT and OUTPUT etc blocks.
                         # params is reset to the contents of orig_params
                         # after the start of each new CASE: block.

        'names',         # Hash ref mapping variable names to Node::Param
                         # objects

        'sig_text',      # The original text of the sig, e.g.
                         #   'param1, int param2 = 0'

        'seen_ellipsis', # Bool: XSUB signature has (   ,...)

        'nargs',         # The number of args expected from caller
        'min_args',      # The minimum number of args allowed from caller

        'auto_function_sig_override', # the C_ARGS value, if any

    );

    fields->import(@FIELDS) if $USING_FIELDS;
}


# ----------------------------------------------------------------
# Parse the XSUB's signature: $sig->{sig_text}
#
# Split the signature on commas into parameters, while allowing for
# things like '(a = ",", b)'. Then for each parameter, parse its
# various fields and store in a ExtUtils::ParseXS::Node::Param object.
# Store those Param objects within the Sig object, plus any other state
# deduced from the signature, such as min/max permitted number of args.
#
# A typical signature might look like:
#
#    OUT     char *s,             \
#            int   length(s),     \
#    OUTLIST int   size     = 10)
#
# ----------------------------------------------------------------

my ($C_group_rex, $C_arg);

# Group in C (no support for comments or literals)
#
# DAPM 2024: I'm not entirely clear what this is supposed to match.
# It appears to match balanced and possibly nested [], {} etc, with
# similar but possibly unbalanced punctuation within. But the balancing
# brackets don't have to correspond: so [} is just as valid as [] or {},
# as is [{{{{] or even [}}}}}

$C_group_rex = qr/ [({\[]
             (?: (?> [^()\[\]{}]+ ) | (??{ $C_group_rex }) )*
             [)}\]] /x;

# $C_arg: match a chunk in C without comma at toplevel (no comments),
# i.e. a single arg within an XS signature, such as
#   foo = ','
#
# DAPM 2024. This appears to match zero, one or more of:
#   a random collection of non-bracket/quote/comma chars (e.g, a word or
#        number or 'int *foo' etc), or
#   a balanced(ish) nested brackets, or
#   a "string literal", or
#   a 'c' char literal
# So (I guess), it captures the next item in a function signature

$C_arg = qr/ (?: (?> [^()\[\]{},"']+ )
       |   (??{ $C_group_rex })
       |   " (?: (?> [^\\"]+ )
         |   \\.
         )* "        # String literal
              |   ' (?: (?> [^\\']+ ) | \\. )* ' # Char literal
       )* /xs;


sub parse {
    my ExtUtils::ParseXS::Node::Sig $self = shift;
    my ExtUtils::ParseXS            $pxs  = shift;

    # remove line continuation chars (\)
    $self->{sig_text} =~ s/\\\s*/ /g;
    my $sig_text = $self->{sig_text};

    my @param_texts;
    my $opt_args = 0; # how many params with default values seen
    my $nargs    = 0; # how many args are expected

    # First, split signature into separate parameters

    if ($sig_text =~ /\S/) {
        my $sig_c = "$sig_text ,";
        use re 'eval'; # needed for 5.16.0 and earlier
        my $can_use_regex = ($sig_c =~ /^( (??{ $C_arg }) , )* $ /x);
        no re 'eval';

        if ($can_use_regex) {
            # If the parameters are capable of being split by using the
            # fancy regex, do so. This splits the params on commas, but
            # can handle things like foo(a = ",", b)
            use re 'eval';
            @param_texts = ($sig_c =~ /\G ( (??{ $C_arg }) ) , /xg);
        }
        else {
            # This is the fallback parameter-splitting path for when the
            # $C_arg regex doesn't work. This code path should ideally
            # never be reached, and indicates a design weakness in $C_arg.
            @param_texts = split(/\s*,\s*/, $sig_text);
            Warn($pxs, "Warning: cannot parse parameter list '$sig_text', fallback to split");
        }
    }
    else {
        @param_texts = ();
    }

    # C++ methods get a fake object/class param at the start.
    # This affects arg numbering.
    if (defined($pxs->{xsub_class})) {
        my ($var, $type) =
            ($pxs->{xsub_seen_static} or $pxs->{xsub_func_name} eq 'new')
                ? ('CLASS', "char *")
                : ('THIS',  "$pxs->{xsub_class} *");

        my ExtUtils::ParseXS::Node::Param $param
                = ExtUtils::ParseXS::Node::Param->new( {
                        var          => $var,
                        type         => $type,
                        is_synthetic => 1,
                        arg_num      => ++$nargs,
                    });
        push @{$self->{params}}, $param;
        $self->{names}{$var} = $param;
        $param->check($pxs)
    }

    # For non-void return types, add a fake RETVAL parameter. This triggers
    # the emitting of an 'int RETVAL;' declaration or similar, and (e.g. if
    # later flagged as in_output), triggers the emitting of code to return
    # RETVAL's value.
    #
    # Note that a RETVAL param can be in three main states:
    #
    #  fully-synthetic  What is being created here. RETVAL hasn't appeared
    #                   in a signature or INPUT.
    #
    #  semi-real        Same as fully-synthetic, but with a defined
    #                   arg_num, and with an updated position within
    #                   @{$self->{params}}.
    #                   A RETVAL has appeared in the signature, but
    #                   without a type yet specified, so it continues to
    #                   use {xsub_return_type}.
    #
    #  real             is_synthetic, no_init flags turned off. Its
    #                   type comes from the sig or INPUT line. This is
    #                   just a normal parameter now.

    if ($pxs->{xsub_return_type} ne 'void') {
        my ExtUtils::ParseXS::Node::Param $param =
            ExtUtils::ParseXS::Node::Param->new( {
                var          => 'RETVAL',
                type         => $pxs->{xsub_return_type},
                no_init      => 1, # just declare the var, don't initialise it
                is_synthetic => 1,
            } );

        push @{$self->{params}}, $param;
        $self->{names}{RETVAL} = $param;
        $param->check($pxs)
    }

    for (@param_texts) {
        # Process each parameter. A parameter is of the general form:
        #
        #    OUT char* foo = expression
        #
        #  where:
        #    IN/OUT/OUTLIST etc are only allowed under
        #                      $pxs->{config_allow_inout}
        #
        #    a C type       is only allowed under
        #                      $pxs->{config_allow_argtypes}
        #
        #    foo            can be a plain C variable name, or can be
        #    length(foo)    but only under $pxs->{config_allow_argtypes}
        #
        #    = default      default value - only allowed under
        #                      $pxs->{config_allow_argtypes}

        s/^\s+//;
        s/\s+$//;

        # Process ellipsis (...)

        $pxs->blurt("further XSUB parameter seen after ellipsis (...)")
            if $self->{seen_ellipsis};

        if ($_ eq '...') {
            $self->{seen_ellipsis} = 1;
            next;
        }

        # Decompose parameter into its components.
        # Note that $name can be either 'foo' or 'length(foo)'

        my ($out_type, $type, $name, $sp1, $sp2, $default) =
                /^
                     (?:
                         (IN|IN_OUT|IN_OUTLIST|OUT|OUTLIST)
                         \b\s*
                     )?
                     (.*?)                             # optional type
                     \s*
                     \b
                     (   \w+                           # var
                         | length\( \s*\w+\s* \)       # length(var)
                     )
                     (?:
                            (\s*) = (\s*) ( .*?)       # default expr
                     )?
                     \s*
                 $
                /x;

        unless (defined $name) {
            if (/^ SV \s* \* $/x) {
                # special-case SV* as a placeholder for backwards
                # compatibility.
                push @{$self->{params}},
                    ExtUtils::ParseXS::Node::Param->new( {
                        var     => 'SV *',
                        arg_num => ++$nargs,
                    });
            }
            else {
                $pxs->blurt("Unparseable XSUB parameter: '$_'");
            }
            next;
        }

        undef $type unless length($type) && $type =~ /\S/;

        my ExtUtils::ParseXS::Node::Param $param
                = ExtUtils::ParseXS::Node::Param->new( {
                        var => $name,
                    });

        # Check for duplicates

        my $old_param = $self->{names}{$name};
        if ($old_param) {
            if (    $name eq 'RETVAL'
                    and $old_param->{is_synthetic}
                    and !defined $old_param->{arg_num})
            {
                # RETVAL is currently fully synthetic. Now that it has
                # been declared as a parameter too, override any implicit
                # RETVAL declaration. Delete the original param from the
                # param list.
                @{$self->{params}} = grep $_ != $old_param, @{$self->{params}};
                # If the param declaration includes a type, it becomes a
                # real parameter. Otherwise the param is kept as
                # 'semi-real' (synthetic, but with an arg_num) until such
                # time as it gets a type set in INPUT, which would remove
                # the synthetic/no_init.
                $param = $old_param if !defined $type;
            }
            else {
                $pxs->blurt(
                        "Error: duplicate definition of parameter '$name' ignored");
                next;
            }
        }

        push @{$self->{params}}, $param;
        $self->{names}{$name} = $param;

        # Process optional IN/OUT etc modifier

        if (defined $out_type) {
            if ($pxs->{config_allow_inout}) {
                $out_type =  $out_type eq 'IN' ? '' : $out_type;
            }
            else {
                $pxs->blurt("parameter IN/OUT modifier not allowed under -noinout");
            }
        }
        else {
            $out_type = '';
        }

        # Process optional type

        if (defined($type) && !$pxs->{config_allow_argtypes}) {
            $pxs->blurt("parameter type not allowed under -noargtypes");
            undef $type;
        }

        # Process 'length(foo)' pseudo-parameter

        my $is_length;
        my $len_name;

        if ($name =~ /^length\( \s* (\w+) \s* \)\z/x) {
            if ($pxs->{config_allow_argtypes}) {
                $len_name = $1;
                $is_length = 1;
                if (defined $default) {
                    $pxs->blurt("Default value not allowed on length() parameter '$len_name'");
                    undef $default;
                }
            }
            else {
                $pxs->blurt("length() pseudo-parameter not allowed under -noargtypes");
            }
        }

        # Handle ANSI params: those which have a type or 'length(s)',
        # and which thus don't need a matching INPUT line.

        if (defined $type or $is_length) { # 'int foo' or 'length(foo)'
            @$param{qw(type is_ansi)} = ($type, 1);

            if ($is_length) {
                $param->{no_init}   = 1;
                $param->{is_length} = 1;
                $param->{len_name}  = $len_name;
            }
        }

        $param->{in_out} = $out_type if length $out_type;
        $param->{no_init} = 1        if $out_type =~ /^OUT/;

        # Process the default expression, including making the text
        # to be used in "usage: ..." error messages.
        my $report_def = '';
        if (defined $default) {
            $opt_args++;
            # The default expression for reporting usage. For backcompat,
            # sometimes preserve the spaces either side of the '='
            $report_def =    ((defined $type or $is_length) ? '' : $sp1)
                           . "=$sp2$default";
            $param->{default_usage} = $report_def;
            $param->{default} = $default;
        }

        if ($out_type eq "OUTLIST" or $is_length) {
            $param->{arg_num} = undef;
        }
        else {
            $param->{arg_num} = ++$nargs;
        }
    } # for (@param_texts)

    $self->{nargs}    = $nargs;
    $self->{min_args} = $nargs - $opt_args;
}


# Return a string to be used in "usage: .." error messages.

sub usage_string {
    my ExtUtils::ParseXS::Node::Sig $self = shift;

    my @args = map  {
                          $_->{var}
                        . (defined $_->{default_usage}
                            ?$_->{default_usage}
                            : ''
                          )
                    }
               grep {
                        defined $_->{arg_num},
                    }
               @{$self->{params}};

    push @args, '...' if $self->{seen_ellipsis};
    return join ', ', @args;
}


# $self->C_func_signature():
#
# return a string containing the arguments to pass to an autocall C
# function, e.g. 'a, &b, c'.

sub C_func_signature {
    my ExtUtils::ParseXS::Node::Sig $self = shift;
    my ExtUtils::ParseXS            $pxs  = shift;

    my @args;
    for my $param (@{$self->{params}}) {
        next if    $param->{is_synthetic} # THIS/CLASS/RETVAL
                   # if a synthetic RETVAL has acquired an arg_num, then
                   # it's appeared in the signature (although without a
                   # type) and has become semi-real.
                && !($param->{var} eq 'RETVAL' && defined($param->{arg_num}));

        if ($param->{is_length}) {
            push @args, "XSauto_length_of_$param->{len_name}";
            next;
        }

        if ($param->{var} eq 'SV *') {
            #backcompat placeholder
            $pxs->blurt("Error: parameter 'SV *' not valid as a C argument");
            next;
        }

        my $io = $param->{in_out};
        $io = '' unless defined $io;

        # Ignore fake/alien stuff, except an OUTLIST arg, which
        # isn't passed from perl (so no arg_num), but *is* passed to
        # the C function and then back to perl.
        next unless defined $param->{arg_num} or $io eq 'OUTLIST';
        
        my $a = $param->{var};
        $a = "&$a" if $param->{is_addr} or $io =~ /OUT/;
        push @args, $a;
    }

    return join(", ", @args);
}


# $self->proto_string():
#
# return a string containing the perl prototype string for this XSUB,
# e.g. '$$;$$@'.

sub proto_string {
    my ExtUtils::ParseXS::Node::Sig $self = shift;

    # Generate a prototype entry for each param that's bound to a real
    # arg. Use '$' unless the typemap for that param has specified an
    # overridden entry.
    my @p = map  defined $_->{proto} ? $_->{proto} : '$',
            grep defined $_->{arg_num} && $_->{arg_num} > 0,
            @{$self->{params}};

    my @sep = (';'); # separator between required and optional args
    my $min = $self->{min_args};
    if ($min < $self->{nargs}) {
        # has some default vals
        splice (@p, $min, 0, ';');
        @sep = (); # separator already added
    }
    push @p, @sep, '@' if $self->{seen_ellipsis};  # '...'
    return join '', @p;
}

1;

# vim: ts=4 sts=4 sw=4: et:
