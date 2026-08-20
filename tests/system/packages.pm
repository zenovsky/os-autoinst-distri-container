use Mojo::Base 'basetest';
use testapi;

sub run {
    my $package = 'wget';

    # Check RPM
    assert_script_run(
        'rpm --version',
        timeout => 10
    );

    # Check DNF
    assert_script_run(
        'dnf --version',
        timeout => 10
    );

    # Check RPM database
    assert_script_run(
        'rpm -qa | head',
        timeout => 10
    );

    record_info(
        'Package manager',
        'rpm and dnf are available'
    );

    # Check package is not installed
    assert_script_run(
        "! rpm -q $package",
        timeout => 10
    );

    # Install package
    assert_script_run(
        "dnf install -y $package",
        timeout => 120
    );

    record_info(
        'Package installed',
        "Installed package: $package"
    );

    # Verify package
    assert_script_run(
        "rpm -q $package",
        timeout => 10
    );

    # Check package executable
    assert_script_run(
        "$package --version",
        timeout => 10
    );

    # Remove package
    assert_script_run(
        "dnf remove -y $package",
        timeout => 120
    );

    # Verify removal
    assert_script_run(
        "! rpm -q $package",
        timeout => 10
    );

    record_info(
        'Package removed',
        "Removed package: $package"
    );
}

1;