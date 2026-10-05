use Mojo::Base 'basetest';
use testapi;

sub run {
    my $username = 'openqa_test';

    # Create test user
    assert_script_run(
        "useradd -m -s /bin/bash $username",
        timeout => 10
    );

    record_info(
        'User created',
        "Created user: $username"
    );

    # Check user exists
    assert_script_run(
        "id $username",
        timeout => 10
    );

    assert_script_run(
        "getent passwd $username",
        timeout => 10
    );

    # Check home directory
    assert_script_run(
        "test -d /home/$username",
        timeout => 10
    );

    # Check shell
    assert_script_run(
        "getent passwd $username | grep '/bin/bash\$'",
        timeout => 10
    );

    # Check command execution as user
    my $whoami = script_output(
        "su - $username -c 'whoami'",
        timeout => 10
    );

    chomp $whoami;

    record_info(
        'User execution',
        "whoami as $username: $whoami"
    );

    die "Unexpected username: $whoami\n"
      unless $whoami eq $username;

    # Remove test user
    assert_script_run(
        "userdel -r $username",
        timeout => 10
    );

    record_info(
        'User removed',
        "Removed user: $username"
    );

    # Verify user and home directory are gone
    assert_script_run(
        "! id $username",
        timeout => 10
    );

    assert_script_run(
        "! test -d /home/$username",
        timeout => 10
    );
}

1;
