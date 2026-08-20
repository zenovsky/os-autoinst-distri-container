use Mojo::Base 'basetest';
use testapi;

sub run {
    my $service = 'systemd-journald';

    # Check service exists
    assert_script_run(
        "systemctl list-unit-files ${service}.service",
        timeout => 10
    );

    # Check service is active
    assert_script_run(
        "systemctl is-active --quiet ${service}.service",
        timeout => 10
    );

    record_info(
        'Service status',
        "$service is active"
    );

    # Check service is enabled/disabled state
    my $enabled = script_output(
        "systemctl is-enabled $service || true",
        timeout => 10
    );

    chomp $enabled;

    record_info(
        'Service enablement',
        "$service: $enabled"
    );

    # Check systemd can list services
    assert_script_run(
        'systemctl list-units --type=service --no-pager',
        timeout => 10
    );
}

1;