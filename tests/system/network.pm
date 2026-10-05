use Mojo::Base 'basetest';
use testapi;

sub run {
    # Check network interfaces
    my $interfaces = script_output(
        'ip -br link',
        timeout => 10
    );

    record_info(
        'Network interfaces',
        $interfaces
    );

    die "No network interfaces found\n"
      unless $interfaces =~ /\S+/;

    # Check IPv4 address
    my $ipv4 = script_output(
        'ip -4 -br addr',
        timeout => 10
    );

    record_info(
        'IPv4 configuration',
        $ipv4
    );

    die "No IPv4 address configured\n"
      unless $ipv4 =~ /\d+\.\d+\.\d+\.\d+\/\d+/;

    # Check default route
    my $route = script_output(
        'ip route show default',
        timeout => 10
    );

    chomp $route;

    record_info(
        'Default route',
        $route
    );

    die "Default route is missing\n"
      unless length $route;

    # Check gateway connectivity
    my ($gateway) = $route =~ /default via ([0-9.]+)/;

    if ($gateway) {
        assert_script_run(
            "ping -c 3 -W 2 $gateway",
            timeout => 15
        );

        record_info(
            'Gateway',
            "Gateway $gateway is reachable"
        );
    }
    else {
        record_info(
            'Gateway',
            'Default route does not contain an IPv4 gateway'
        );
    }

    # Check DNS resolution
    assert_script_run(
        'getent hosts localhost',
        timeout => 10
    );

    record_info(
        'DNS',
        'Host name resolution is working'
    );
}

1;
