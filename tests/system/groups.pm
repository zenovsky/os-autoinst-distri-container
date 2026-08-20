use Mojo::Base 'basetest';
use testapi;

sub run {
    my $groupname = 'openqa_test_group';
    my $username  = 'openqa_group_test';

    # Create test group
    assert_script_run(
        "groupadd $groupname",
        timeout => 10
    );

    record_info(
        'Group created',
        "Created group: $groupname"
    );

    # Check group exists
    assert_script_run(
        "getent group $groupname",
        timeout => 10
    );

    # Create test user
    assert_script_run(
        "useradd $username",
        timeout => 10
    );

    # Add user to group
    assert_script_run(
        "usermod -a -G $groupname $username",
        timeout => 10
    );

    # Verify group membership
    assert_script_run(
        "id -nG $username | grep -qw $groupname",
        timeout => 10
    );

    record_info(
        'Group membership',
        "$username is a member of $groupname"
    );

    # Remove user
    assert_script_run(
        "userdel $username",
        timeout => 10
    );

    # Remove group
    assert_script_run(
        "groupdel $groupname",
        timeout => 10
    );

    # Verify group was removed
    assert_script_run(
        "! getent group $groupname",
        timeout => 10
    );
}

1;