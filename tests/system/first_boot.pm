use Mojo::Base 'basetest';
use testapi;
use StepReport;

my $root_password = get_var('ROOT_PASSWORD', '12345678');

sub run {
    add_step_secret($root_password);

    step 'Step 1. System has started up' => sub {
        assert_screen 'console-root', 720;
    };
    
    step 'Step 2. Login as Root' => sub {
        type_string 'root';
        send_key 'ret';
        wait_still_screen(3);
        type_string $root_password;
        send_key 'ret';
        assert_screen 'console-root-access', 720
    };
    
}

sub test_flags {
    return { fatal => 1 };
}

1;
