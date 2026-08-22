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
    my %stage_id;

    for my $i (0 .. $#{$scenario->{stages}}) {
        my $stage = $scenario->{stages}[$i];

        $stage_id{$stage->{name}} = $i;

        $params{"TEST:$i"} = $stage->{scenario};
    }

    for my $stage (@{$scenario->{stages}}) {
        my $name = $stage->{name};

        if (defined $stage->{START_AFTER_TEST}) {
            my $parent = $stage->{START_AFTER_TEST};

            die "Unknown START_AFTER_TEST stage '$parent'\n"
                unless exists $stage_id{$parent};

            $params{"_START_AFTER:$stage_id{$name}"} =
                $stage_id{$parent};
        }

        if ($stage->{type} eq 'parallel'
            && defined $stage->{START_AFTER_TEST}) {

            my $parent = $stage->{START_AFTER_TEST};

            $params{"_PARALLEL:$stage_id{$name}"} =
                $stage_id{$parent};
        }
    }

    return \%params;
}

1;