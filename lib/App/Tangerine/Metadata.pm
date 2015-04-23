package App::Tangerine::Metadata;
use strict;
use warnings;
use overload
    '""' => sub {
        return $_[0]->type."\0".$_[0]->name."\0".$_[0]->file
    },
    'cmp' => sub {
        my ($self, $other) = @_;
        return "$self" cmp "$other"
    };


sub new {
    my $class = shift;
    my %args = @_; 
    bless { %args }, $class
}

sub accessor {
    $_[1]->{$_[0]} = $_[2] ? $_[2] : $_[1]->{$_[0]}
}

sub name { accessor(name => @_) }
sub file { accessor(file => @_) }
sub type { accessor(type => @_) }
sub line { accessor(line => @_) }
sub version { accessor(version => @_) }

1;
