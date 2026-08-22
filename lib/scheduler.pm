package scheduler;

use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(load_yaml_schedule);

use YAML::PP;
use testapi qw(get_var set_var);
use autotest;

# Loads and executes a schedule described in YAML_SCHEDULE, if that setting is present.
# Returns 1 if a schedule was loaded and executed, 0 if YAML_SCHEDULE is not set.
sub load_yaml_schedule {
    my $yaml_schedule = get_var('YAML_SCHEDULE') or return 0;

    my $casedir = get_var('CASEDIR', '.');
    my $path    = "$casedir/$yaml_schedule";
    die "YAML_SCHEDULE file not found: $path\n" unless -e $path;

    my $ypp  = YAML::PP->new(schema => ['Core']);
    my $data = $ypp->load_file($path);

    _apply_vars($data->{vars} // {});

    my @modules = _expand(
        $data->{schedule} // [],
        $data->{conditional_schedule} // {}
    );

    autotest::loadtest($_) for @modules;

    return 1;
}

# Sets job vars from the YAML file, but never overrides a value already
# passed to the job explicitly (e.g. via CLI/API settings).
sub _apply_vars {
    my ($vars) = @_;
    for my $key (keys %$vars) {
        set_var($key, $vars->{$key}) unless defined get_var($key);
    }
    return;
}

# Walks a `schedule` list, replacing '{{placeholder}}' entries with the
# modules resolved from `conditional_schedule`. Supports nested placeholders.
sub _expand {
    my ($schedule, $conditional) = @_;
    my @result;
    for my $item (@$schedule) {
        if ($item =~ /^\{\{\s*(\S+)\s*\}\}$/) {
            my $key    = $1;
            my $branch = $conditional->{$key};
            die "conditional_schedule has no key '$key' referenced by {{$key}}\n" unless $branch;
            push @result, _expand(_resolve($branch), $conditional);
        }
        else {
            push @result, $item;
        }
    }
    return @result;
}

# Given a conditional_schedule branch like { VAR => { value1 => [...], value2 => [...] } },
# picks the list matching the current value of VAR (or '+undefined' if VAR is unset).
sub _resolve {
    my ($branch) = @_;
    for my $var (keys %$branch) {
        my $value = get_var($var);
        my $list =
            defined $value && exists $branch->{$var}{$value} ? $branch->{$var}{$value}
          : exists $branch->{$var}{'+undefined'}              ? $branch->{$var}{'+undefined'}
          :                                                      undef;
        return @$list if $list;
    }
    return ();
}

1;