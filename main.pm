use Mojo::Base -strict;
use testapi;
use autotest;

my $casedir = get_var('CASEDIR');

die "CASEDIR is not set\n"
    unless $casedir;

unshift @INC, "$casedir/lib";

require ScenarioLoader;

my $scenario_name = get_var('SCENARIO', 'smoke');

my $loader = ScenarioLoader->new(
    scenario_dir => "$casedir/scenarios"
);

my $scenario = $loader->load($scenario_name);

# ------------------------------------------------------------
# Parallel scenario
#
# Each openQA job executes only the tests assigned to that
# logical parallel job.
# ------------------------------------------------------------

my $parallel_job = get_var('PARALLEL_JOB');

if ($scenario->{type} eq 'parallel') {

    die "PARALLEL_JOB is not set\n"
        unless defined $parallel_job
        && length $parallel_job;

    my ($job) = grep {
        $_->{name} eq $parallel_job
    } @{$scenario->{jobs}};

    die "Parallel job '$parallel_job' not found "
        . "in scenario '$scenario_name'\n"
        unless $job;

    for my $test (@{$job->{tests} // []}) {
        autotest::loadtest $test;
    }

    return 1;
}

# ------------------------------------------------------------
# Normal test/image scenario
# ------------------------------------------------------------

for my $test (@{$scenario->{tests} // []}) {
    autotest::loadtest $test;
}

1;