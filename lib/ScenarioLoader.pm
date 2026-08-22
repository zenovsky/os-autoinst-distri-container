package ScenarioLoader;

use strict;
use warnings;

use YAML::XS qw(LoadFile);
use File::Spec;

sub new {
    my ($class, %args) = @_;

    my $scenario_dir = $args{scenario_dir}
        // die "scenario_dir is required\n";

    die "Scenario directory not found: $scenario_dir\n"
        unless -d $scenario_dir;

    return bless {
        scenario_dir => $scenario_dir,
    }, $class;
}

sub load {
    my ($self, $name) = @_;

    my %seen;

    return $self->_load($name, \%seen);
}

sub _load {
    my ($self, $name, $seen) = @_;

    die "Scenario name is empty\n"
        unless defined $name && length $name;

    die "Circular scenario include detected: $name\n"
        if $seen->{$name};

    $seen->{$name} = 1;

    my $file = File::Spec->catfile(
        $self->{scenario_dir},
        "$name.yaml"
    );

    die "Scenario file not found: $file\n"
        unless -f $file;

    my $scenario = LoadFile($file);

    die "Scenario file is empty: $file\n"
        unless $scenario;

    die "Scenario must contain 'name': $file\n"
        unless exists $scenario->{name};

    die "Scenario must contain 'type': $file\n"
        unless exists $scenario->{type};

    my $type = $scenario->{type};

    die "Unsupported scenario type '$type': $file\n"
        unless $type eq 'test'
            || $type eq 'image'
            || $type eq 'parallel'
            || $type eq 'regression';

    #
    # Validate variables
    #

    $self->_validate_variables(
        $scenario,
        $file
    );

    #
    # TEST
    #

    if ($type eq 'test') {

        $self->_validate_test_scenario(
            $scenario,
            $file
        );
    }

    #
    # IMAGE
    #

    elsif ($type eq 'image') {

        $self->_validate_image_scenario(
            $scenario,
            $file
        );

        #
        # Resolve source scenario
        #

        if (exists $scenario->{source}) {

            die "'source' must be a mapping: $file\n"
                unless ref($scenario->{source}) eq 'HASH';

            die "Image source must contain 'scenario': $file\n"
                unless exists $scenario->{source}->{scenario};

            my $source_name =
                $scenario->{source}->{scenario};

            my $source =
                $self->_load(
                    $source_name,
                    $seen
                );

            die "Image source scenario '$source_name' "
                . "must have type 'test': $file\n"
                unless $source->{type} eq 'test';

            #
            # Tests from source scenario
            #

            my @tests = (
                @{$source->{tests} // []},
                @{$scenario->{tests} // []},
            );

            $scenario->{tests} = \@tests;

            #
            # Variables from source scenario
            #

            my %variables = (
                %{$source->{variables} // {}},
                %{$scenario->{variables} // {}},
            );

            $scenario->{variables} = \%variables
                if %variables;
        }
    }

    #
    # PARALLEL
    #

    elsif ($type eq 'parallel') {

        $self->_validate_parallel_scenario(
            $scenario,
            $file
        );
    }

    #
    # REGRESSION
    #

    elsif ($type eq 'regression') {

        $self->_validate_regression_scenario(
            $scenario,
            $file,
            $seen
        );
    }

    #
    # INCLUDE
    #

    if (exists $scenario->{include}) {

        die "'include' must be an array: $file\n"
            unless ref($scenario->{include}) eq 'ARRAY';

        my @tests;
        my %variables;

        for my $included (
            @{$scenario->{include}}
        ) {

            my $included_scenario =
                $self->_load(
                    $included,
                    $seen
                );

            die "Included scenario '$included' "
                . "must have type 'test'\n"
                unless $included_scenario->{type} eq 'test';

            push @tests,
                @{$included_scenario->{tests} // []};

            %variables = (
                %variables,
                %{$included_scenario->{variables} // {}},
            );
        }

        push @tests,
            @{$scenario->{tests} // []};

        $scenario->{tests} = \@tests;

        %variables = (
            %variables,
            %{$scenario->{variables} // {}},
        );

        $scenario->{variables} = \%variables
            if %variables;
    }

    #
    # FINAL VALIDATION
    #

    if ($type eq 'test' || $type eq 'image') {

        die "Scenario contains no tests: $file\n"
            unless exists $scenario->{tests}
            && ref($scenario->{tests}) eq 'ARRAY'
            && @{$scenario->{tests}};
    }

    elsif ($type eq 'parallel') {

        die "Parallel scenario contains no jobs: $file\n"
            unless exists $scenario->{jobs}
            && ref($scenario->{jobs}) eq 'ARRAY'
            && @{$scenario->{jobs}};
    }

    elsif ($type eq 'regression') {

        die "Regression scenario contains no stages: $file\n"
            unless exists $scenario->{stages}
            && ref($scenario->{stages}) eq 'ARRAY'
            && @{$scenario->{stages}};
    }

    delete $seen->{$name};

    return $scenario;
}

#
# ------------------------------------------------------------
# TEST
# ------------------------------------------------------------
#

sub _validate_test_scenario {
    my ($self, $scenario, $file) = @_;

    $self->_validate_tests(
        $scenario,
        $file
    );
}

#
# ------------------------------------------------------------
# IMAGE
# ------------------------------------------------------------
#

sub _validate_image_scenario {
    my ($self, $scenario, $file) = @_;

    die "Image scenario must contain 'source': $file\n"
        unless exists $scenario->{source};

    die "Image scenario must contain 'image': $file\n"
        unless exists $scenario->{image};

    die "'image' must be a mapping: $file\n"
        unless ref($scenario->{image}) eq 'HASH';

    die "Image scenario must contain 'image.size_gb': $file\n"
        unless exists $scenario->{image}->{size_gb};

    die "Image scenario must contain 'image.name': $file\n"
        unless exists $scenario->{image}->{name};

    die "'image.size_gb' must be a positive integer: $file\n"
        unless defined $scenario->{image}->{size_gb}
        && $scenario->{image}->{size_gb} =~ /^\d+$/
        && $scenario->{image}->{size_gb} > 0;

    die "'image.name' must be a non-empty string: $file\n"
        unless defined $scenario->{image}->{name}
        && !ref($scenario->{image}->{name})
        && length $scenario->{image}->{name};
}

#
# ------------------------------------------------------------
# TESTS
# ------------------------------------------------------------
#

sub _validate_tests {
    my ($self, $scenario, $file) = @_;

    die "Scenario must contain 'tests': $file\n"
        unless exists $scenario->{tests};

    die "'tests' must be an array: $file\n"
        unless ref($scenario->{tests}) eq 'ARRAY';

    die "Scenario contains no tests: $file\n"
        unless @{$scenario->{tests}};

    for my $test (@{$scenario->{tests}}) {

        die "Test path must be a non-empty string: $file\n"
            unless defined $test
            && !ref($test)
            && length $test;

        my $test_file = File::Spec->catfile(
            $self->{scenario_dir},
            '..',
            $test
        );

        die "Test file not found: $test\n"
            unless -f $test_file;
    }
}

#
# ------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------
#

sub _validate_variables {
    my ($self, $scenario, $file) = @_;

    return
        unless exists $scenario->{variables};

    die "'variables' must be a hash: $file\n"
        unless ref($scenario->{variables}) eq 'HASH';

    for my $key (
        keys %{$scenario->{variables}}
    ) {

        die "Variable name must be a non-empty string: $file\n"
            unless defined $key && length $key;

        die "Variable '$key' must have a scalar value: $file\n"
            if ref($scenario->{variables}{$key});
    }
}

#
# ------------------------------------------------------------
# PARALLEL
# ------------------------------------------------------------
#

sub _validate_parallel_scenario {
    my ($self, $scenario, $file) = @_;

    die "Parallel scenario must contain 'jobs': $file\n"
        unless exists $scenario->{jobs};

    die "'jobs' must be an array: $file\n"
        unless ref($scenario->{jobs}) eq 'ARRAY';

    die "Parallel scenario contains no jobs: $file\n"
        unless @{$scenario->{jobs}};

    my %job_names;

    for my $job (
        @{$scenario->{jobs}}
    ) {

        die "Parallel job must be a mapping: $file\n"
            unless ref($job) eq 'HASH';

        die "Parallel job must contain 'name': $file\n"
            unless exists $job->{name};

        die "Parallel job name must be a non-empty string: $file\n"
            unless defined $job->{name}
            && !ref($job->{name})
            && length $job->{name};

        my $name = $job->{name};

        die "Duplicate parallel job name '$name': $file\n"
            if $job_names{$name}++;

        die "Parallel job '$name' must contain 'tests': $file\n"
            unless exists $job->{tests};

        die "Parallel job '$name' tests must be an array: $file\n"
            unless ref($job->{tests}) eq 'ARRAY';

        die "Parallel job '$name' contains no tests: $file\n"
            unless @{$job->{tests}};

        for my $test (
            @{$job->{tests}}
        ) {

            die "Test path must be a non-empty string: $file\n"
                unless defined $test
                && !ref($test)
                && length $test;

            my $test_file = File::Spec->catfile(
                $self->{scenario_dir},
                '..',
                $test
            );

            die "Test file not found: $test\n"
                unless -f $test_file;
        }

        if (exists $job->{PARALLEL_WITH}) {

            die "PARALLEL_WITH for job '$name' must be "
                . "a non-empty string: $file\n"
                unless defined $job->{PARALLEL_WITH}
                && !ref($job->{PARALLEL_WITH})
                && length $job->{PARALLEL_WITH};
        }
    }

    #
    # Validate PARALLEL_WITH references
    #

    for my $job (
        @{$scenario->{jobs}}
    ) {

        next
            unless exists $job->{PARALLEL_WITH};

        my $target =
            $job->{PARALLEL_WITH};

        die "Parallel job '$job->{name}' references "
            . "unknown job '$target': $file\n"
            unless $job_names{$target};
    }
}

#
# ------------------------------------------------------------
# REGRESSION
# ------------------------------------------------------------
#

sub _validate_regression_scenario {
    my ($self, $scenario, $file, $seen) = @_;

    die "Regression scenario must contain 'stages': $file\n"
        unless exists $scenario->{stages};

    die "'stages' must be an array: $file\n"
        unless ref($scenario->{stages}) eq 'ARRAY';

    die "Regression scenario contains no stages: $file\n"
        unless @{$scenario->{stages}};

    my %stage_names;

    for my $stage (
        @{$scenario->{stages}}
    ) {

        die "Regression stage must be a mapping: $file\n"
            unless ref($stage) eq 'HASH';

        die "Regression stage must contain 'name': $file\n"
            unless exists $stage->{name};

        die "Regression stage name must be a non-empty string: $file\n"
            unless defined $stage->{name}
            && !ref($stage->{name})
            && length $stage->{name};

        my $stage_name =
            $stage->{name};

        die "Duplicate regression stage name "
            . "'$stage_name': $file\n"
            if $stage_names{$stage_name}++;

        die "Regression stage '$stage_name' must contain "
            . "'type': $file\n"
            unless exists $stage->{type};

        my $type =
            $stage->{type};

        die "Regression stage '$stage_name' has unsupported "
            . "type '$type': $file\n"
            unless $type eq 'test'
                || $type eq 'image'
                || $type eq 'parallel';

        die "Regression stage '$stage_name' must contain "
            . "'scenario': $file\n"
            unless exists $stage->{scenario};

        die "Regression stage '$stage_name' scenario must be "
            . "a non-empty string: $file\n"
            unless defined $stage->{scenario}
            && !ref($stage->{scenario})
            && length $stage->{scenario};

        #
        # Load referenced scenario and validate it.
        #

        my $referenced =
            $self->_load(
                $stage->{scenario},
                $seen
            );

        die "Regression stage '$stage_name' expects type '$type' "
            . "but scenario '$stage->{scenario}' has type "
            . "'$referenced->{type}': $file\n"
            unless $referenced->{type} eq $type;

        #
        # START_AFTER_TEST
        #

        if (exists $stage->{START_AFTER_TEST}) {

            my $value =
                $stage->{START_AFTER_TEST};

            if (ref($value) eq 'ARRAY') {

                die "START_AFTER_TEST for regression stage "
                    . "'$stage_name' cannot be empty: $file\n"
                    unless @{$value};

                for my $target (@{$value}) {

                    die "START_AFTER_TEST for regression stage "
                        . "'$stage_name' must contain only "
                        . "non-empty strings: $file\n"
                        unless defined $target
                        && !ref($target)
                        && length $target;
                }
            }
            else {

                die "START_AFTER_TEST for regression stage "
                    . "'$stage_name' must be a string or array: $file\n"
                    unless defined $value
                    && !ref($value)
                    && length $value;
            }
        }

        #
        # PARALLEL_WITH is only meaningful for parallel stages.
        #

        if (exists $stage->{PARALLEL_WITH}) {

            die "PARALLEL_WITH can only be used with "
                . "parallel regression stages: $file\n"
                unless $type eq 'parallel';

            die "PARALLEL_WITH for regression stage "
                . "'$stage_name' must be a non-empty string: $file\n"
                unless defined $stage->{PARALLEL_WITH}
                && !ref($stage->{PARALLEL_WITH})
                && length $stage->{PARALLEL_WITH};
        }
    }

    #
    # Validate START_AFTER_TEST references.
    #

    for my $stage (
        @{$scenario->{stages}}
    ) {

        next
            unless exists $stage->{START_AFTER_TEST};

        my @targets;

        if (ref($stage->{START_AFTER_TEST}) eq 'ARRAY') {

            @targets =
                @{$stage->{START_AFTER_TEST}};
        }
        else {

            @targets =
                ($stage->{START_AFTER_TEST});
        }

        for my $target (@targets) {

            die "Regression stage '$stage->{name}' "
                . "references unknown stage '$target': $file\n"
                unless exists $stage_names{$target};
        }
    }
}

1;