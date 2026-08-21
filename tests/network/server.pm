use Mojo::Base 'basetest';
use testapi;
use lockapi;
use mmapi;

sub run {
    assert_script_run 'ip a';
    assert_script_run 'ip addr add 172.16.2.10/15 dev ens4';
    assert_script_run 'ip link set ens4 up';

    mutex_create 'server_ready';

    wait_for_children;
}

sub test_flags {
    return {fatal => 1};
}

1;