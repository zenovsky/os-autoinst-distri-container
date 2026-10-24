use Mojo::Base 'basetest';
use testapi;
use utf8;
use utils;
use StepReport;

my $root_password = get_var('ROOT_PASSWORD', '12345678');

sub run {
    add_step_secret($root_password);

    step 'Система запущена' => sub {
        step_log 'System has booted up and console is ready for use';
        assert_screen 'console-root', 720;
    };

    step 'Войти как root-пользователь' => sub {
        step_log 'Log in as root user';
        login_as_root();
    };

}

sub test_flags {
    return {fatal => 1};
}

sub post_fail_hook { write_step_report('first-system-boot', failed => 1) }

1;
