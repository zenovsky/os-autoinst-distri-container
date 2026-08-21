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
# Normal scenario
# ------------------------------------------------------------

if ($scenario->{type} ne 'parallel') {

    for my $test (@{$scenario->{tests} // []}) {
        autotest::loadtest $test;
    }

    1;
}

# ------------------------------------------------------------
# Parallel scenario
# ------------------------------------------------------------

my $job_name = get_var('TEST');

die "TEST is not set for parallel scenario '$scenario_name'\n"
    unless defined $job_name && length $job_name;

my $parallel_job;

for my $job (@{$scenario->{jobs} // []}) {

    next unless defined $job->{name};

    if ($job->{name} eq $job_name) {
        $parallel_job = $job;
        last;
    }
}

die "Parallel job '$job_name' not found in scenario "
    . "'$scenario_name'\n"
    unless $parallel_job;

# ------------------------------------------------------------
# Load tests for this parallel job
# ------------------------------------------------------------

for my $test (@{$parallel_job->{tests} // []}) {
    autotest::loadtest $test;
}

1;