use Mojo::Base 'basetest';
use testapi;
use lockapi;

sub run {
    assert_script_run 'ip a';
    assert_script_run 'ip addr add 172.16.2.10/15 dev ens4';
    assert_script_run 'ip link set eth0 up';

    mutex_create 'server_ready';

    sleep 60;
}

sub test_flags {
    return {fatal => 1};
}

1;