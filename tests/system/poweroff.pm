use Mojo::Base 'basetest';
use testapi;

sub run {
    type_string 'poweroff';
    send_key 'ret';
    wait_still_screen(30);
    assert_screen 'poweroff-success', 120;

}

1;