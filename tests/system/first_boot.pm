use Mojo::Base 'basetest';
use testapi;
use utils;
use StepReport;

my $root_password = get_var('ROOT_PASSWORD', '12345678');

sub run {
    add_step_secret($root_password);

    step 'System has started up' => sub {
        step_log 'System has booted up and console is ready for use';
        assert_screen 'console-root', 720;
    };
    
    step 'Login as Root' => sub {
        step_log 'Log in as root user';
        login_as_root();
    };

}

sub test_flags {
    return { fatal => 1 };
}

1;
