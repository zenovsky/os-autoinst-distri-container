use Mojo::Base 'basetest';
use testapi;

sub run {
    my $root_password = get_var('ROOT_PASSWORD', '12345678');

    assert_screen 'bootloader';

    send_key 'up';
    send_key 'ret';

    assert_screen 'anaconda-welcome', 420;

    assert_and_click 'welcome-install-start';
    assert_screen 'anaconda-installation-summary';

    assert_and_click 'anaconda-installation-summary-disk';
    assert_screen 'anaconda-disk-partition';

    assert_and_click 'anaconda-disk-partition-disk-confirm';
    assert_screen 'anaconda-installation-summary';

    assert_and_click 'anaconda-installation-summary-root-user';
    assert_screen 'anaconda-root-user-settings';

    assert_and_click 'anaconda-root-user-settings-root-pick';

    type_string $root_password;
    send_key 'tab';
    type_string $root_password;

    assert_and_click 'anaconda-root-user-settings-ssh-access';

    assert_and_click 'anaconda-root-user-settings-confirm';
    assert_and_click 'anaconda-root-user-settings-confirm';
    assert_screen 'anaconda-installation-summary';

    assert_and_click 'anaconda-installation-summary-start-installation';

    assert_screen 'anaconda-installation-perform';
    assert_screen 'anaconda-installation-perform-finish', 720;
    assert_and_click 'anaconda-installation--perform-restart';
}

sub test_flags {
    return {fatal => 1};
}

1;
