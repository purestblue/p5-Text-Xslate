package Text::Xslate::Parser;
use 5.010;
use Mouse;

use Text::Xslate::Util;
use Text::Xslate::Symbol;

use constant _DUMP_PROTO => ($Text::Xslate::DEBUG =~ /\b dump=proto \b/xmsi);
use constant _DUMP_TOKEN => ($Text::Xslate::DEBUG =~ /\b dump=token \b/xmsi);

our @CARP_NOT = qw(Text::Xslate::Compiler);

my $dquoted = qr/" (?: \\. | [^"\\] )* "/xms; # " for poor editors
my $squoted = qr/' (?: \\. | [^'\\] )* '/xms; # ' for poor editors
my $QUOTED  = qr/(?: $dquoted | $squoted )/xms;

my $NUMBER  = qr/(?: [0-9]+ (?: \. [0-9]+)? )/xms;

my $ID      = qr/(?: [A-Za-z_][A-Za-z0-9_]* )/xms;

my $OPERATOR = sprintf '(?:%s)', join('|', map{ quotemeta } qw(
    ...
    ..
    -- ++
    == != <=> <= >=
    << >>
    && || //
    -> =>
    ::

    < >
    + - * / %
    & | ^ 
    !
    .
    ~
    ? :
    ( )
    { }
    [ ]
    ;
), ',');


my $COMMENT = qr/\# [^\n;]* (?=[;\n])?/xms;

my $CODE    = qr/ (?: (?: $QUOTED | [^'"] )*? ) /xms; # ' for poor editors

has symbol_table => (
    is  => 'ro',
    isa => 'HashRef',

    default  => sub{ {} },

    init_arg => undef,
);

has scope => (
    is  => 'rw',
    isa => 'ArrayRef[HashRef]',

    default => sub{ [ {} ] },

    required => 0,
);

has token => (
    is  => 'rw',
    isa => 'Object',

    init_arg => undef,
);

has input => (
    is  => 'rw',
    isa => 'Str',

    init_arg => undef,
);

has file => (
    is  => 'rw',
    isa => 'Str',

    default  => '<input>',
    required => 0,
);

has line => (
    is  => 'rw',
    isa => 'Int',

    traits  => [qw(Counter)],
    handles => {
        line_inc => 'inc',
    },

    required => 0,
);

has line_start => (
    is      => 'ro',
    isa     => 'Maybe[RegexpRef]',
    default => sub{ qr/\Q:/xms },
);

has tag_start => (
    is      => 'ro',
    isa     => 'RegexpRef',
    default => sub{ qr/\Q<:/xms },
);

has tag_end => (
    is      => 'ro',
    isa     => 'RegexpRef',
    default => sub{ qr/\Q:>/xms },
);


sub _trim {
    my($s) = @_;

    $s =~ s/\A \s+         //xms;
    $s =~ s/   [ \t]+ \n?\z//xms;

    return $s;
}

sub split {
    my ($self, $_) = @_;

    my @tokens;

    my $line_start    = $self->line_start;
    my $tag_start     = $self->tag_start;
    my $tag_end       = $self->tag_end;

    my $lex_line = defined($line_start) && qr/\A ^ [ \t]* $line_start ([^\n]* \n?) /xms;
    my $lex_tag  = qr/\A ([^\n]*?) $tag_start ($CODE) $tag_end /xms;
    my $lex_text = qr/\A ([^\n]* \n) /xms;

    while($_) {
        if($lex_line && s/$lex_line//xms) {
            push @tokens,
                [ code => _trim($1) ];
        }
        elsif(s/$lex_tag//xms) {
            if($1){
                push @tokens, [ text => $1 ];
            }
            push @tokens,
                [ code => _trim($2) ];
        }
        elsif(s/$lex_text//xms) {
            push @tokens, [ text => $1 ];
        }
        else {
            push @tokens, [ text => $_ ];
            last;
        }
    }
    ## tokens: @tokens
    return \@tokens;
}

sub preprocess {
    my $self = shift;

    my $tokens_ref = $self->split(@_);
    my $code = '';

    foreach my $token(@{$tokens_ref}) {
        given($token->[0]) {
            when('text') {
                my $s = $token->[1];
                $s =~ s/(["\\])/\\$1/gxms; # " for poor editors

                if($s =~ s/\n/\\n/xms) {
                    $code .= qq{print_raw "$s";\n};
                }
                else {
                    $code .= qq{print_raw "$s";};
                }
            }
            when('code') {
                my $s = $token->[1];
                $s =~ s/\A =/print/xms;

                #if($s =~ /[\{\}\[\]]\n?\z/xms){ # ???
                if($s =~ /[\}]\n?\z/xms){
                    $code .= $s;
                }
                elsif(chomp $s) {
                    $code .= qq{$s;\n};
                }
                else {
                    $code .= qq{$s;};
                }
            }
            default {
                $self->_parse_error("Unknown token: $_");
            }
        }
    }
    print STDOUT $code, "\n" if _DUMP_PROTO;
    return $code;
}

sub next_token {
    my($self) = @_;

    local *_ = \$self->{input};

    s{\G (\s) }{ $1 eq "\n" and $self->line_inc; ""}xmsge;

    if(s/\A ($ID)//xmso){
        return [ name => $1 ];
    }
    elsif(s/\A ($QUOTED)//xmso){
        return [ string => $1 ];
    }
    elsif(s/\A ($OPERATOR)//xmso){
        return [ operator => $1 ];
    }
    elsif(s/\A ($NUMBER)//xmso){
        return [ number => $1 ];
    }
    elsif(s/\A (\$ $ID)//xmso) {
        return [ variable => $1 ];
    }
    elsif(s/\A $COMMENT //xmso) {
        goto &next_token; # tail call
    }
    elsif(s/\A (\S+)//xms) {
        $self->_parse_error("Unexpected symbol '$1'");
    }
    else { # empty
        return undef;
    }
}

sub parse {
    my($parser, $input) = @_;

    $parser->input( $parser->preprocess($input) );

    return $parser->statements();
}

sub BUILD {
    my($parser) = @_;
    $parser->define_grammer();
    return;
}

# The grammer

sub define_grammer {
    my($parser) = @_;

    # separators
    $parser->symbol(':');
    $parser->symbol(';');
    $parser->symbol(',');
    $parser->symbol(')');
    $parser->symbol(']');
    $parser->symbol('}');
    $parser->symbol('->');
    $parser->symbol('else');
    $parser->symbol('with');
    $parser->symbol('::');

    # meta symbols
    $parser->symbol('(end)');
    $parser->symbol('(name)');

    $parser->symbol('(literal)')->set_nud(\&_nud_literal);
    $parser->symbol('(variable)')->set_nud(\&_nud_literal);

    # operators

    $parser->infix('*', 80);
    $parser->infix('/', 80);
    $parser->infix('%', 80);

    $parser->infix('+', 70);
    $parser->infix('-', 70);

    $parser->infix('~',  70); # connect


    $parser->infix('<',  60);
    $parser->infix('<=', 60);
    $parser->infix('>',  60);
    $parser->infix('>=', 60);

    $parser->infix('==', 50);
    $parser->infix('!=', 50);

    $parser->infix('|',  40); # filter

    $parser->infix('?', 20, \&_led_ternary);

    $parser->infix('.', 100, \&_led_dot);
    $parser->infix('[', 100, \&_led_fetch);
    $parser->infix('(', 100, \&_led_call);

    $parser->infixr('&&', 35);
    $parser->infixr('||', 30);
    $parser->infixr('//', 30);

    $parser->prefix('!');
    $parser->prefix('+');
    $parser->prefix('-');

    $parser->prefix('(', \&_nud_paren);

    # constants
    $parser->define_constant('nil', undef);

    # statements
    $parser->symbol('{')        ->set_std(\&_std_block);
    #$parser->symbol('var')      ->set_std(\&_std_var);
    $parser->symbol('for')      ->set_std(\&_std_for);
    $parser->symbol('if')       ->set_std(\&_std_if);

    $parser->symbol('print')    ->set_std(\&_std_command);
    $parser->symbol('print_raw')->set_std(\&_std_command);

    $parser->symbol('include')  ->set_std(\&_std_command);

    # template inheritance

    $parser->symbol('cascade')  ->set_std(\&_std_bare_command);
    $parser->symbol('macro')    ->set_std(\&_std_proc);
    $parser->symbol('block')    ->set_std(\&_std_proc);
    $parser->symbol('around')   ->set_std(\&_std_proc);
    $parser->symbol('before')   ->set_std(\&_std_proc);
    $parser->symbol('after')    ->set_std(\&_std_proc);
    $parser->symbol('super')    ->set_nud(\&_nud_literal);

    return;
}


sub symbol {
    my($parser, $id, $bp) = @_;

    my $s = $parser->symbol_table->{$id};
    if(defined $s) {
        if($bp && $bp >= $s->lbp) {
            $s->lbp($bp);
        }
    }
    else {
        $s = Text::Xslate::Symbol->new(id => $id);
        $s->lbp($bp) if $bp;
        $parser->symbol_table->{$id} = $s;
    }

    return $s;
}


sub advance {
    my($parser, $id) = @_;

    if($id && $parser->token->id ne $id) {
        $parser->_parse_error("Expected '$id', but " . $parser->token);
    }

    my $symtab = $parser->symbol_table;

    my $t = $parser->next_token();

    if(not defined $t) {
        return $parser->token( $symtab->{"(end)"} );
    }

    print STDOUT "[@{$t}]\n" if _DUMP_TOKEN;

    my($arity, $value) = @{$t};
    my $proto;

    given($arity) {
        when("name") {
            $proto = $parser->find($value);
        }
        when("variable") {
            $proto = $parser->find($value);

            if($proto->id eq '(name)') { # undefined variable
                $proto = $symtab->{'(variable)'};
            }
        }
        when("operator") {
            $proto = $symtab->{$value};
            if(!$proto) {
                $parser->_parse_error("Unknown operator '$value'");
            }
        }
        when("string") {
            $proto = $symtab->{"(literal)"};
            $arity = "literal";
        }
        when("number") {
            $proto = $symtab->{"(literal)"};
            $arity = "literal";
        }
    }

    if(!$proto) {
        $parser->_parse_error("Unexpected token: $value ($arity)");
    }

    return $parser->token( $proto->clone( id => $value, arity => $arity, line => $parser->line + 1 ) );
}

sub expression {
    my($parser, $rbp) = @_;

    my $t = $parser->token;

    $parser->advance();

    my $left = $t->nud($parser);

    while($rbp < $parser->token->lbp) {
        $t = $parser->token;
        $parser->advance();
        $left = $t->led($parser, $left);
    }

    return $left;
}

sub _led_infix {
    my($parser, $symbol, $left) = @_;
    my $bin = $symbol->clone(arity => 'binary');

    $bin->first($left);
    $bin->second($parser->expression($bin->lbp));
    return $bin;
}

sub infix {
    my($parser, $id, $bp, $led) = @_;

    $parser->symbol($id, $bp)->set_led($led || \&_led_infix);
    return;
}

sub _led_infixr {
    my($parser, $symbol, $left) = @_;
    my $bin = $symbol->clone(arity => 'binary');
    $bin->first($left);
    $bin->second($parser->expression($bin->lbp - 1));
    return $bin;
}

sub infixr {
    my($parser, $id, $bp, $led) = @_;

    $parser->symbol($id, $bp)->set_led($led || \&_led_infixr);
    return;
}

sub _led_ternary {
    my($parser, $symbol, $left) = @_;

    my $cond = $symbol->clone(arity => 'ternary');

    $cond->first($left);
    $cond->second($parser->expression(0));
    $parser->advance(":");
    $cond->third($parser->expression(0));
    return $cond;
}

sub _led_dot {
    my($parser, $symbol, $left) = @_;

    my $t = $parser->token;
    if($t->arity ne 'name') {
        $parser->_parse_error("Expected a field name");
    }

    my $dot = $symbol->clone(arity => 'binary');

    $dot->first($left);
    $dot->second($t->clone(arity => 'literal'));

    $parser->advance();
    return $dot;
}

sub _led_fetch {
    my($parser, $symbol, $left) = @_;

    my $fetch = $symbol->clone(arity => 'binary');

    $fetch->first($left);
    $fetch->second($parser->expression(0));

    $parser->advance("]");
    return $fetch;
}

sub _led_call {
    my($parser, $symbol, $left) = @_;

    my $call = $symbol->clone(arity => 'call');

    if(!( $left->arity ~~ [qw(function name variable macro literal)] )) {
        $parser->_parse_error("Expected a function, not " . $left->arity . " ($left)");
    }

    $call->first($left);

    my @args;
    if($parser->token->id ne ")") {
        while(1) {
            push @args, $parser->expression(0);
            if($parser->token->id ne ",") {
                last;
            }
            $parser->advance(",");
        }
    }
    $parser->advance(")");

    $call->second(\@args);

    return $call;
}

sub _nud_prefix {
    my($parser, $symbol) = @_;
    my $un = $symbol->clone(arity => 'unary');
    $parser->reserve($un);
    $un->first($parser->expression(90));
    return $un;
}

sub prefix {
    my($parser, $id, $nud) = @_;

    $parser->symbol($id)->set_nud($nud || \&_nud_prefix);
    return;
}

sub _nud_constant {
    my($parser, $symbol) = @_;

    my $c = $symbol->clone(arity => 'literal');
    $parser->reserve($c);

    return $c;
}

sub define_constant {
    my($parser, $id, $value) = @_;

    my $symbol = $parser->symbol($id);
    $symbol->set_nud(\&_nud_constant);
    $symbol->value($value);
    return;
}

sub new_scope {
    my($parser) = @_;
    push @{ $parser->scope }, {};
    return;
}

sub find { # find a name from all the scopes
    my($parser, $name) = @_;

    foreach my $scope(reverse @{$parser->scope}){
        my $o = $scope->{$name};
        if($o) {
            return $o;
        }
    }

    my $symtab = $parser->symbol_table;
    return $symtab->{$name} || $symtab->{'(name)'};
}

sub reserve { # reserve a name to the scope
    my($parser, $symbol) = @_;
    if($symbol->arity ne 'name' or $symbol->reserved) {
        return;
    }

    my $top = $parser->scope->[-1];
    my $t = $top->{$symbol->value};
    if($t) {
        if($t->reserved) {
            return;
        }
        if($t->arity eq "name") {
           confess("Already defined: $symbol");
        }
    }
    $top->{$symbol->value} = $symbol;
    $symbol->reserved(1);
    return;
}

sub define { # define a name to the scope
    my($parser, $symbol) = @_;
    my $top = $parser->scope->[-1];

    my $t = $top->{$symbol->value};
    if(defined $t) {
        confess($t->reserved ? "Already reserved: $t" : "Already defined: $t");
    }

    $top->{$symbol->value} = $symbol;

    $symbol->reserved(0);
    $symbol->set_nud(\&_nud_literal);
    $symbol->remove_led();
    $symbol->remove_std();
    $symbol->lbp(0);
    #$symbol->scope($top);
    return $symbol;
}


sub _nud_function{
    my($p, $s) = @_;
    my $f = $s->clone(arity => 'function');
    $p->reserve($f);
    return $f;
}

sub define_function {
    my($compiler, @names) = @_;

    foreach my $name(@names) {
        my $symbol = $compiler->symbol($name);
        $symbol->set_nud(\&_nud_function);
        $symbol->value($name);
    }
    return;
}

sub _nud_macro{
    my($p, $s) = @_;
    my $f = $s->clone(arity => 'macro');
    $p->reserve($f);
    return $f;
}

sub define_macro {
    my($compiler, @names) = @_;

    foreach my $name(@names) {
        my $symbol = $compiler->symbol($name);
        $symbol->set_nud(\&_nud_macro);
        $symbol->value($name);
    }
    return;
}


sub pop_scope {
    my($parser) = @_;
    pop @{ $parser->scope };
    return;
}

sub statement { # process one or more statements
    my($parser) = @_;
    my $t = $parser->token;

    if($t->id eq ";"){
        $parser->advance(";");
        return;
    }

    if($t->has_std) { # is $t a statement?
        $parser->advance();
        $parser->reserve($t);
        return $t->std($parser);
    }

    my $expr = $parser->expression(0);
#    if($expr->assignment && $expr->id ne "(") {
#        confess("Bad expression statement");
#    }
    $parser->advance(";");
    return $expr;
}

sub statements { # process statements
    my($parser) = @_;
    my @a;

    $parser->advance();
    while(1) {
        my $t = $parser->token;
        if($t->id eq "}" || $t->id eq "(end)") {
            last;
        }

        push @a, $parser->statement();
    }

    return \@a;
    #return @a == 1 ? $a[0] : \@a;
}

sub block {
    my($parser) = @_;
    my $t = $parser->token;
    $parser->advance("{");
    return $t->std($parser);
}


sub _nud_literal {
    my($parser, $symbol) = @_;
    return $symbol->clone();
}

sub _nud_paren {
    my($parser, $symbol) = @_;
    my $expr = $parser->expression(0);
    $parser->advance(')');
    return $expr;
}

sub _std_block {
    my($parser, $symbol) = @_;
    $parser->new_scope();
    my $a = $parser->statements();
    $parser->advance('}');
    $parser->pop_scope();
    return $a;
}

#sub _std_var {
#    my($parser, $symbol) = @_;
#    my @a;
#    while(1) {
#        my $name = $parser->token;
#        if($name->arity ne "variable") {
#            confess("Expected a new variable name, but $name is not");
#        }
#        $parser->define($name);
#        $parser->advance();
#
#        if($parser->token->id eq "=") {
#            my $t = $parser->token;
#            $parser->advance("=");
#            $t->first($name);
#            $t->second($parser->expression(0));
#            $t->arity("binary");
#            push @a, $t;
#        }
#
#        if($parser->token->id ne ",") {
#            last;
#        }
#        $parser->advance(",");
#    }
#
#    $parser->advance(";");
#    return @a;
#}

sub _std_for {
    my($parser, $symbol) = @_;

    my $proc = $symbol->clone(arity => "for");

    $proc->first( $parser->expression(0) );

    $parser->new_scope();

    $parser->advance("->");
    $parser->advance("(");

    my @vars;

    while((my $t = $parser->token)->arity eq "variable") {
        push @vars, $t;
        $parser->define($t);
        $parser->advance;
    }

    $proc->second( \@vars );

    $parser->advance(")");
    $parser->advance("{");
    $proc->third($parser->statements());
    $parser->advance("}");

    $parser->pop_scope();

    return $proc;
}

sub _std_proc {
    my($parser, $symbol) = @_;

    my $proc = $symbol->clone(arity => "proc");
    my $name = $parser->token;
    if($name->arity ne "name") {
        $parser->_parse_error("Expected name, but " . $parser->token . " is not");
    }

    $parser->define_macro($name->id);
    $proc->first( $name->id );
    $parser->advance();

    $parser->new_scope();
    $parser->advance("->");
    my @vars;
    if($parser->token->id eq "(") {
        $parser->advance("(");

        while((my $t = $parser->token)->arity eq "variable") {
            push @vars, $t;
            $parser->define($t);
            $parser->advance;

            if($parser->token->id eq ",") {
                $parser->advance(",");
            }
        }

        $parser->advance(")");
    }
    $proc->second( \@vars );

    $parser->advance("{");
    $proc->third($parser->statements());
    $parser->advance("}");
    $parser->pop_scope();

    return $proc;
}

sub _std_if {
    my($parser, $symbol) = @_;

    my $if = $symbol->clone(arity => "if");

    $if->first( $parser->expression(0) );
    $if->second( $parser->block() );

    if($parser->token->id eq "else") {
        $parser->reserve($parser->token);
        $parser->advance("else");
        $if->third( $parser->token->id eq "if"
            ? $parser->statement()
            : $parser->block ());
    }
    return $if;
}

sub _std_command {
    my($parser, $symbol) = @_;
    my @args;
    if($parser->token->id ne ";") {
        while(1) {
            push @args, $parser->expression(0);

            if($parser->token->id ne ",") {
                last;
            }
            $parser->advance(",");
        }
    }
    $parser->advance(";");
    return $symbol->clone(first => \@args, arity => 'command');
}

sub _get_namespaced_name {
    my($parser) = @_;
    my @parts;

    my $t = $parser->token;
    if($t->arity ne "name") {
        $parser->_parse_error("Expected name, but $t is not");
    }

    push @parts, $t->id;
    $parser->advance();

    while(1) {
        my $t = $parser->token;

        if($t->id eq "::") {
            $t = $parser->advance("::");

            if($t->arity ne "name") {
                $parser->_parse_error("Expected name, but $t is not");
            }

            push @parts, $t->id;
            $parser->advance();
        }
        else {
            last;
        }
    }
    return join "::", @parts;
}

sub _std_bare_command {
    my($parser, $symbol) = @_;

    my $name = $parser->_get_namespaced_name();
    my @components;

    if($parser->token->id eq 'with') {
        $parser->advance('with');

        push @components, $parser->_get_namespaced_name();
        while($parser->token->id eq ',') {
            $parser->advance(',');

            push @components, $parser->_get_namespaced_name();
        }
    }
    $parser->advance(";");
    return $symbol->clone(
        first  => $name,
        second => \@components,
        arity  => 'bare_command');
}

sub _parse_error {
    my($self, $message) = @_;

    Carp::croak(sprintf 'Xslate::Parser(%s:%d): %s', $self->file, $self->line+1, $message);
}

no Mouse;
__PACKAGE__->meta->make_immutable;
__END__

=head1 NAME

Text::Xslate::Parser - An Xslate template parser used by default

=cut