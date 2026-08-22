package ScenarioRunner;

use strict;
use warnings;

use ScenarioLoader;

sub new {
    my ($class, %args) = @_;

    my $scenario_dir =
        $args{scenario_dir}
        // die "scenario_dir is required\n";

    my $self = {
        scenario_dir => $scenario_dir,
    };

    return bless $self, $class;
}

sub load {
    my ($self, $name) = @_;

    my $loader = ScenarioLoader->new(
        scenario_dir => $self->{scenario_dir},
    );

    return $loader->load($name);
}

sub openqa_params {
    my ($self, $scenario_name) = @_;

    my $scenario = $self->load($scenario_name);

    my %params;

    for my $stage (@{$scenario->{stages}}) {
        my $name = $stage->{name};
        my $type = $stage->{type};
        my $test = $stage->{scenario} // $name;

        $params{"TEST:$name"} = $test;

        if (defined $stage->{START_AFTER_TEST}) {
            $params{"_START_AFTER:$name"} =
                $stage->{START_AFTER_TEST};
        }

        if ($type eq 'parallel') {
            my $parent = $stage->{START_AFTER_TEST};

            die "Parallel stage '$name' requires START_AFTER_TEST\n"
                unless defined $parent;

            $params{"_PARALLEL:$name"} = $parent;
        }
    }

    return \%params;
}

1;