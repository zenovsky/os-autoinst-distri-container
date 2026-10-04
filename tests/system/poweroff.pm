use Mojo::Base 'basetest';
use testapi;
use utils;
use StepReport;

sub run {
    step 'Poweroff system' => sub {
        step_log 'System shutdown';
        poweroff();
    };

}

sub test_flags {
    return { fatal => 1 };
}

1;