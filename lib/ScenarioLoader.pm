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
        unless $type eq 'test' || $type eq 'image';

    #
    # Validate variables
    #
    $self->_validate_variables($scenario, $file);

    #
    # TEST scenario
    #
    if ($type eq 'test') {

        $self->_validate_test_scenario($scenario, $file);

    }

    #
    # IMAGE scenario
    #
    elsif ($type eq 'image') {

        $self->_validate_image_scenario($scenario, $file);

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
                $self->_load($source_name, $seen);

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
    # Process include
    #
    if (exists $scenario->{include}) {

        die "'include' must be an array: $file\n"
            unless ref($scenario->{include}) eq 'ARRAY';

        my @tests;
        my %variables;

        for my $included (@{$scenario->{include}}) {

            my $included_scenario =
                $self->_load($included, $seen);

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
    # Final validation
    #
    if ($type eq 'test' || $type eq 'image') {

        die "Scenario contains no tests: $file\n"
            unless exists $scenario->{tests}
            && ref($scenario->{tests}) eq 'ARRAY'
            && @{$scenario->{tests}};
    }

    delete $seen->{$name};

    return $scenario;
}

sub _validate_test_scenario {
    my ($self, $scenario, $file) = @_;

    $self->_validate_tests($scenario, $file);
}

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

sub _validate_variables {
    my ($self, $scenario, $file) = @_;

    return unless exists $scenario->{variables};

    die "'variables' must be a hash: $file\n"
        unless ref($scenario->{variables}) eq 'HASH';

    for my $key (keys %{$scenario->{variables}}) {

        die "Variable name must be a non-empty string: $file\n"
            unless defined $key && length $key;

        die "Variable '$key' must have a scalar value: $file\n"
            if ref($scenario->{variables}{$key});
    }
}

1;