use Mojo::Base 'basetest';
use testapi;

sub run {
    assert_script_run(
        'test -d /etc',
        timeout => 10
    );

    assert_script_run(
        'test -d /var',
        timeout => 10
    );

    assert_script_run(
        'test -d /usr',
        timeout => 10
    );

    assert_script_run(
        'test -d /home',
        timeout => 10
    );

    assert_script_run(
        'findmnt /',
        timeout => 10
    );

    assert_script_run(
        'findmnt /proc',
        timeout => 10
    );

    assert_script_run(
        'findmnt /sys',
        timeout => 10
    );

    assert_script_run(
        'findmnt /dev',
        timeout => 10
    );
}

1;