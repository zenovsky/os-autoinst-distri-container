package ScenarioRunner;

use strict;
use warnings;

use YAML::PP;
use Carp qw(croak);

sub new {
    my ($class, %args) = @_;

    croak "scenario_dir is required"
        unless $args{scenario_dir};

    return bless {
        scenario_dir => $args{scenario_dir},
    }, $class;
}

sub load {
    my ($self, $scenario_name) = @_;

    croak "scenario name is required"
        unless $scenario_name;

    my $file = "$self->{scenario_dir}/$scenario_name.yaml";

    croak "Scenario file not found: $file"
        unless -f $file;

    my $yaml = YAML::PP->new;
    my $data = $yaml->load_file($file);

    croak "Scenario '$scenario_name' must contain 'stages'"
        unless ref($data->{stages}) eq 'ARRAY';

    return $data;
}

sub openqa_params {
    my ($self, $scenario_name, %args) = @_;

    my $scenario = $self->load($scenario_name);

    my %params;

    my $index = 0;
    my %stage_index;

    for my $stage (@{$scenario->{stages}}) {
        my $name = $stage->{name};
        my $test = $stage->{scenario};

        croak "Stage is missing name"
            unless defined $name;

        croak "Stage '$name' is missing scenario"
            unless defined $test;

        $stage_index{$name} = $index;

        $params{"TEST:$index"} = $test;

        if (defined $stage->{START_AFTER_TEST}) {
            my $parent = $stage->{START_AFTER_TEST};

            croak "Stage '$name' depends on unknown stage '$parent'"
                unless exists $stage_index{$parent};

            $params{"_START_AFTER:$index"} = $stage_index{$parent};
        }

        if ($stage->{type} && $stage->{type} eq 'parallel') {
            if (defined $stage->{START_AFTER_TEST}) {
                my $parent = $stage->{START_AFTER_TEST};
                $params{"_PARALLEL:$index"} = $stage_index{$parent};
            }
        }

        $index++;
    }

    return \%params;
}

1;