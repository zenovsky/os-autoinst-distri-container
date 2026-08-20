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

for my $test (@{$scenario->{tests} // []}) {
    autotest::loadtest $test;
}

1;