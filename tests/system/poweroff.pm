use Mojo::Base 'basetest';
use testapi;
use StepReport;

sub run {
    step 'Step 1. Poweroff system' => sub {
        type_string 'poweroff';
        send_key 'ret';
        wait_still_screen(30);
        assert_screen 'poweroff-success', 120;   
    };
    
}

1;