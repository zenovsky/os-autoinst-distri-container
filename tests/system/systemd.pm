use Mojo::Base 'basetest';
use testapi;

sub run {
    assert_script_run(
        'test "$(ps -p 1 -o comm=)" = systemd',
        timeout => 10
    );

    my $state = script_output(
        'systemctl is-system-running || true'
    );

    chomp $state;

    record_info(
        'systemd state',
        "systemctl is-system-running: $state"
    );

    assert_script_run(
        'systemctl --version',
        timeout => 10
    );
}

1;