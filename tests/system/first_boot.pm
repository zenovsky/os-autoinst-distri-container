use Mojo::Base 'basetest';
use testapi;

sub run {
    my $root_password = get_var('ROOT_PASSWORD', '12345678');

    assert_screen 'console-root', 720;
    type_string 'root';
    send_key 'ret';
    type_string $root_password;
    send_key 'ret';
    assert_screen 'console-root-access', 720;
}

1;
