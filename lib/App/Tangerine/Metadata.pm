package App::Tangerine::Metadata;
use strict;
use warnings;

sub new {
    my $class = shift;
    my %args = @_; 
    bless { %args }, $class
}

sub accessor {
    $_[1]->{$_[0]} = $_[2] ? $_[2] : $_[1]->{$_[0]}
}

sub dcompare {
    $_[0]->name eq $_[1]->name &&
    $_[0]->file eq $_[1]->file &&
    $_[0]->type eq $_[1]->type
}

sub name { accessor(name => @_) }
sub file { accessor(file => @_) }
sub type { accessor(type => @_) }
sub line { accessor(line => @_) }
sub version { accessor(version => @_) }

1;
