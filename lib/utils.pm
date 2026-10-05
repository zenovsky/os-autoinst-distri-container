package utils;

use base Exporter;
use Exporter;
use Mojo::Base -strict;
use Mojo::Base 'basetest';
use testapi;
use autotest;

our @EXPORT = qw(
  reboot
  login_as_root
  poweroff
  click_and_wait
  click_right_and_wait
  send_key_and_wait
  type_safely

);

my $root_password = get_var('ROOT_PASSWORD', '12345678');

# Root login
sub login_as_root {
    type_string 'root';
    send_key 'ret';
    wait_still_screen(3);
    type_string $root_password;
    send_key 'ret';
    assert_screen 'console-root-access', 720;
}

# System reboot
sub reboot {
    enter_cmd 'reboot';
    wait_still_screen(15);
    assert_screen 'console-root', 720;
    type_string 'root';
    send_key 'ret';
    wait_still_screen(3);
    type_string $root_password;
    send_key 'ret';
    assert_screen 'console-root-access', 720;
}

# Poweroff system
sub poweroff {
    type_string 'poweroff';
    send_key 'ret';
    wait_still_screen(30);
    assert_screen 'poweroff-success', 120;
}

# Left-click and wait
sub click_and_wait {
    my ($button, $wait_time) = @_;
    assert_and_click($button);
    wait_still_screen($wait_time // 1);
}

# Right-click and wait
sub click_right_and_wait {
    my ($button, $wait_time) = @_;
    assert_and_click($button, button => 'right');
    wait_still_screen($wait_time // 1);
}

# Send key and wait
sub send_key_and_wait {
    my ($key, $wait_time) = @_;
    send_key($key, wait_screen_change => $wait_time // 5);
}

# Careful text entry
sub type_safely {
    my $string = shift;
    type_string($string, wait_screen_change => 3, max_interval => 20, wait_still_screen => 2, similarity_level => 38);
}

1;
