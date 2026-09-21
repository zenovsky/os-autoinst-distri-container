package utils;

use base Exporter;
use Exporter;
use Mojo::Base -strict;
use Mojo::Base 'basetest';
use testapi;
use autotest;
use warnings;
use strict;

our @EXPORT = qw(reboot) 

# System reboot
sub reboot {
    enter_cmd "reboot";
    wait_still_screen(15);
    assert_screen 'console-root', 720;
    type_string 'root';
    send_key 'ret';
    wait_still_screen(3);
    type_string $root_password;
    send_key 'ret';
    assert_screen 'console-root-access', 720;

}

1;