# openQA test
#
# Summary: OpenSSH (Server) — configuration and security checks, service
# restart, system reboot, log analysis, general OS status.
# Qase case: "OpenSSH Server - Проверка конфигурации и параметров безопасности"
# Paired module: ssh_client.pm — runs on a second machine in the same
use Mojo::Base 'basetest';
use utf8;
use testapi;
use lockapi;
use mmapi;
use utils;
use StepReport;

my $client_ip = get_var('SSH_CLIENT_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

sub run {
    add_step_secret($test_pass);

    # Synchronisation points shared with ssh_client.pm (names must match on both sides)
    barrier_create($_, 2) for qw(
      user_ready
      server_ready
      failed_logins_done
      faillock_checked
      client_checks_done
      perms_broken
      client_perm_checked
      perms_restored
      server_sshd_restarted
      client_restart_checked
      server_rebooted
      client_reboot_checked
    );

    # Обеспечена сетевая связанность между машинами SERVER и CLIENT:
    step 'Предусловие. Сетевая связанность с клиентом (ping)' => sub {
        run_cmd "Checking connectivity to the client $client_ip (4 ICMP echo requests)" => "ping -c 4 $client_ip";
    };

    # На SERVER существует тестовый пользователь ssh_test_user с заданным паролем:
    step 'Предусловие. Тестовый пользователь ssh_test_user' => sub {
        run_cmd "Creating user $test_user with shell /bin/bash" => "useradd -m -s /bin/bash $test_user";
        run_cmd "Setting the password for $test_user" => "echo '$test_user:$test_pass' | chpasswd";
        run_cmd 'Opening permissions on /dev/ttyS0 (chmod 777)' => 'chmod 777 /dev/ttyS0';
    };

    barrier_wait 'user_ready';

    step 'Проверка валидности конфигурации sshd' => sub {
        run_cmd 'Validating the sshd configuration (sshd -t)' => 'sshd -t';
        run_cmd 'Printing the effective security-related sshd settings' =>
          'sshd -T | grep -E '
          . q{'^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|usepam|authorizedkeysfile|allowusers|denyusers) '};
        run_cmd 'Checking that the effective configuration uses port 22' => q{sshd -T | grep -x 'port 22'};
    };

    step 'Проверка используемых алгоритмов (криптостойкость)' => sub {
        my $algs = q{sshd -T | grep -E '^(ciphers|macs|kexalgorithms|hostkeyalgorithms|pubkeyacceptedalgorithms) '};
        run_cmd 'Printing the effective ciphers, MACs, KEX, host key and pubkey algorithms' => $algs;
        run_cmd 'Checking that no legacy algorithms are enabled' =>
          "! $algs | grep -Ei '3des-cbc|aes128-cbc|hmac-md5|diffie-hellman-group1-sha1|(^|[ ,])ssh-rsa(,|\$)'";
        run_cmd 'Checking that modern ciphers and key exchange are present' =>
          q{sshd -T | grep -E '^ciphers ' | grep -E 'chacha20-poly1305|aes(128|256)-gcm'}
          . q{ && sshd -T | grep -E '^kexalgorithms ' | grep curve25519};
    };

    step 'Проверка настройки интеграции sshd с PAM' => sub {
        run_cmd 'Checking that usepam is enabled' => q{sshd -T | grep -x 'usepam yes'};
        run_cmd 'Checking that /etc/pam.d/sshd exists' => 'ls -l /etc/pam.d/sshd';
    };

    step 'Запуск и добавление службы sshd в автозагрузку' => sub {
        run_cmd 'Enabling the sshd service at boot and starting it now' => 'systemctl enable --now sshd';
        run_cmd 'Checking that sshd is active and enabled' => 'systemctl is-active sshd && systemctl is-enabled sshd';
    };

    step 'Проверить прослушивание 22 порта' => sub {
        run_cmd 'Checking that port 22 is in LISTEN state and owned by sshd' =>
          q{ss -lntp | grep -E 'sshd|:22[[:space:]]'};
    };

    step 'Проверка и настройка Firewalld для SSH' => sub {
        run_cmd 'Checking that firewalld is active' => 'systemctl is-active firewalld';
        run_cmd 'Checking that the ssh service is allowed in the public zone' =>
          q{firewall-cmd --zone=public --list-services | grep -w 'ssh'};
        run_cmd 'Reloading firewalld and checking that the ssh rule persists' =>
          'firewall-cmd --reload && firewall-cmd --query-service=ssh';
    };

    # sshd is up and reachable: the client may start its checks
    barrier_wait 'server_ready';

    step 'Проверка владельца и прав приватного host key' => sub {
        run_cmd 'Checking that the ed25519 host key is 600 root:root' =>
          q{stat -c '%a %U:%G' /etc/ssh/ssh_host_ed25519_key | grep -x '600 root:root'};
    };

    step 'Проверка режима SELinux (Enforcing)' => sub {
        run_cmd 'Checking that SELinux is in Enforcing mode' => q{getenforce | grep 'Enforcing'};
    };

    step 'Проверка меток файловой системы (SELinux context)' => sub {
        run_cmd 'Printing SELinux contexts of sshd and sshd_config' => 'ls -Z /usr/sbin/sshd /etc/ssh/sshd_config';
        run_cmd 'Checking that /usr/sbin/sshd has the sshd_exec_t type' => q{ls -Z /usr/sbin/sshd | grep 'sshd_exec_t'};
        run_cmd 'Checking that /etc/ssh/sshd_config has the etc_t type' => q{ls -Z /etc/ssh/sshd_config | grep 'etc_t'};
        run_cmd 'Checking that /etc/ssh needs no relabeling' => q{! restorecon -nR /etc/ssh 2>&1 | grep -i 'would relabel'};
    };

    step 'Проверка отсутствия отказов SELinux (AVC denials) с момента загрузки' => sub {
        run_cmd 'Checking for the absence of AVC denials since boot' =>
          q{! ausearch -m AVC,USER_AVC -ts boot | grep -q denied};
    };

    # The client has made 3 attempts with a wrong password
    barrier_wait 'failed_logins_done';

    step 'Проверка работы модуля PAM (Блокировка faillock)' => sub {
        run_cmd "Printing the faillock records of $test_user" => "faillock --user $test_user";
        # Do not let a possible lockout break the password login in the client's next steps
        run_cmd "Resetting the faillock counter of $test_user" => "faillock --user $test_user --reset", quiet => 1;
    };

    barrier_wait 'faillock_checked';
    barrier_wait 'client_checks_done';

    step 'Проверка StrictModes: небезопасные права на ~/.ssh' => sub {
        run_cmd "Making /home/$test_user/.ssh world-writable (chmod 777)" => "chmod 777 /home/$test_user/.ssh";
        barrier_wait 'perms_broken';

        step_log 'Waiting for the client to try the key login (it must be refused)';
        barrier_wait 'client_perm_checked';

        # Permissions must be restored even if the journal check fails, otherwise the client hangs
        my $ok = eval {
            run_cmd 'Looking for "bad ownership or modes" in the sshd journal' =>
              "journalctl -u sshd --no-pager --since '-5min' | grep 'bad ownership or modes'";
            1;
        };
        my $err = $@;
        run_cmd "Restoring permissions on /home/$test_user/.ssh (chmod 700)" => "chmod 700 /home/$test_user/.ssh";
        barrier_wait 'perms_restored';
        die $err unless $ok;
    };

    step 'Перезапуск службы sshd и проверка работоспособности' => sub {
        run_cmd 'Restarting the sshd service' => 'systemctl restart sshd';
        run_cmd 'Checking that sshd is active after the restart' => 'systemctl is-active sshd';
    };

    barrier_wait 'server_sshd_restarted';
    barrier_wait 'client_restart_checked';

    step 'Перезагрузка системы и проверка автозапуска' => sub {
        step_log 'Rebooting the server and waiting for the console login';
        reboot();
        run_cmd 'Checking that sshd is active after the reboot' => 'systemctl is-active sshd';
    };

    barrier_wait 'server_rebooted';
    barrier_wait 'client_reboot_checked';

    step 'Анализ логов службы и PAM' => sub {
        run_cmd 'Looking for error/failed/fatal entries in the sshd journal of the current boot' =>
          q{! journalctl -u sshd --no-pager -b | grep -iE 'error|failed|fatal'}
          . q{ | grep -v 'bad ownership or modes' | grep -v 'Failed publickey'};
    };

    step 'Проверка целостности установленного пакета' => sub {
        run_cmd 'Verifying the openssh package files (rpm -V)' => 'rpm -V openssh', quiet => 1;
    };

    step 'Проверка отсутствия упавших systemd-юнитов' => sub {
        run_cmd 'Checking that there are no failed systemd units' => q{systemctl --failed | grep '0 loaded units listed'};
    };
}

sub post_fail_hook { write_step_report('openssh-server', failed => 1, qase_id => get_var('QASE_CASE_ID')) }
sub post_run_hook { write_step_report('openssh-server', qase_id => get_var('QASE_CASE_ID')) }

1;
