use Mojo::Base 'basetest';
use testapi;

sub run {
    my $kernel = script_output('uname -r');
    my $arch   = script_output('uname -m');

    chomp $kernel;
    chomp $arch;

    record_info(
        'Kernel',
        "Kernel: $kernel\nArchitecture: $arch"
    );

    die "Kernel version is empty\n"
        unless length $kernel;

    die "Architecture is empty\n"
        unless length $arch;

    assert_script_run(
        'uname -r',
        timeout => 10
    );

    assert_script_run(
        'uname -m',
        timeout => 10
    );

    assert_script_run(
        'test -d /lib/modules/$(uname -r)',
        timeout => 10
    );
}

1;