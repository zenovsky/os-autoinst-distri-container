use Mojo::Base 'basetest';
use testapi;

sub run {
    my $hostname = script_output('hostname');

    chomp $hostname;

    record_info(
        'Hostname',
        "System hostname: $hostname"
    );

    die "Hostname is empty\n"
      unless length $hostname;

    assert_script_run(
        'hostnamectl --static',
        timeout => 10
    );
}

1;
