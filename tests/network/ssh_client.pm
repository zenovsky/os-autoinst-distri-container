# openQA test
# Summary: OpenSSH (Client) — password/key authentication, host key handling,
# invalid key and weak cipher rejection, scp/sftp, StrictModes, checks after
# sshd restart and server reboot.
# Qase case: "OpenSSH Client - Проверка методов аутентификации, SSH-ключей и безопасности"
# Paired module: ssh_server.pm — runs on a second machine in the same
use Mojo::Base 'basetest';
use utf8;
use testapi;
use lockapi;
use mmapi;
use StepReport;

my $server_ip = get_var('SSH_SERVER_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

my $key = '~/.ssh/id_ed25519_test';
my $wrong_key = '~/.ssh/id_ed25519_wrong';
my $target = "$test_user\@$server_ip";
my $askpass = '/tmp/askpass.sh';

# Environment that makes ssh/ssh-copy-id/scp take the password from $askpass instead of the terminal.
# Lets us test password authentication without needles for the password prompt.
sub askpass_env {
    my ($pw) = @_;
    return "ASKPASS_PW='$pw' SSH_ASKPASS=$askpass SSH_ASKPASS_REQUIRE=force";
}

# Runs $cmd, requires a NON-zero exit code and $pattern (case-insensitive) in its combined output.
sub expect_fail {
    my ($desc, $cmd, $pattern, %opt) = @_;
    return run_cmd $desc => "out=\$($cmd 2>&1); rc=\$?; test \$rc -ne 0 && echo \"\$out\" | grep -qi '$pattern'", %opt;
}

sub run {
    add_step_secret($test_pass);

    # Обеспечена сетевая связанность между машинами SERVER и CLIENT:
    step 'Предусловие. Сетевая связанность с сервером (ping)' => sub {
        run_cmd "Checking connectivity to the server $server_ip (4 ICMP echo requests)" => "ping -c 4 $server_ip";
    };

    # Technical helper of the autotest, not a step of the Qase case, so it is not a report step.
    # Writes a tiny script that prints $ASKPASS_PW (the password never lands in the file), which lets
    # ssh/ssh-copy-id/scp take the password non-interactively via SSH_ASKPASS.
    my $mk = <<'EOT';
printf '#!/bin/sh\nprintf "%%s\\n" "$ASKPASS_PW"\n' > /tmp/askpass.sh && chmod 700 /tmp/askpass.sh
EOT
    chomp $mk;
    assert_script_run $mk;

    barrier_wait 'user_ready';
    barrier_wait 'server_ready';

    step 'Проверка доступности 22 порта на сервере' => sub {
        run_cmd "Scanning $server_ip:22 and looking for the OpenSSH banner" =>
          "ssh-keyscan -p 22 -T 2 $server_ip 2>&1 | grep -q OpenSSH";
    };

    step 'Проверка аутентификации по паролю (PAM-аутентификация)' => sub {
        my $out = run_cmd "Logging in to $target with the password and running whoami && pwd" =>
          askpass_env($test_pass)
          . " ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no $target 'whoami && pwd'";
        die "Expected '$test_user' in the output\n" unless $out =~ /^\Q$test_user\E$/m;
        die "Expected '/home/$test_user' in the output\n" unless $out =~ m{^/home/\Q$test_user\E$}m;
    };

    step 'Проверка сохранения host key сервера в known_hosts' => sub {
        run_cmd "Looking up $server_ip in ~/.ssh/known_hosts" => "ssh-keygen -F $server_ip";
    };

    step 'Проверка работы PAM faillock на клиенте/сервере (Неверный пароль)' => sub {
        expect_fail "Trying 3 times to log in to $target with a wrong password" =>
          askpass_env('WrongPassword!1')
          . " ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=3 $target",
          'Permission denied, please try again';
    };

    barrier_wait 'failed_logins_done';

    step 'Генерация пары SSH-ключей Ed25519' => sub {
        run_cmd "Generating an ed25519 key pair $key without a passphrase" => "ssh-keygen -t ed25519 -f $key -N ''";
        run_cmd 'Checking that the private and public key files exist' => "ls -l $key*";
        run_cmd 'Checking that the private key has mode 600' => qq{test "\$(stat -c %a $key)" = 600};
    };

    barrier_wait 'faillock_checked';

    step 'Копирование публичного ключа на сервер' => sub {
        my $out = run_cmd "Copying the public key to $target with ssh-copy-id (password from the helper)" =>
          askpass_env($test_pass) . " ssh-copy-id -i $key.pub $target";
        die "ssh-copy-id did not report 'Number of key(s) added: 1'\n" unless $out =~ /Number of key\(s\) added:\s*1/;
    };

    step 'Проверка аутентификации по ключу (без пароля)' => sub {
        my $out = run_cmd "Logging in to $target with the key without a password and running whoami" =>
          "ssh -i $key -o PasswordAuthentication=no -o StrictHostKeyChecking=no $target 'whoami'";
        die "Expected '$test_user' in the output\n" unless $out =~ /^\Q$test_user\E$/m;
    };

    step 'Проверка контекстов SELinux для добавленного ключа на сервере' => sub {
        run_cmd 'Checking that authorized_keys on the server has the ssh_home_t type' =>
          "ssh -i $key -o PasswordAuthentication=no -o StrictHostKeyChecking=yes $target 'ls -Za ~/.ssh/authorized_keys' | grep 'ssh_home_t'";
    };

    step 'Отклонение доступа при использовании некорректного ключа' => sub {
        run_cmd 'Generating a second key pair that is not installed on the server' =>
          "ssh-keygen -t ed25519 -f $wrong_key -N ''";
        expect_fail 'Trying to log in with the wrong key and expecting "Permission denied"' =>
          "ssh -i $wrong_key -o PasswordAuthentication=no -o StrictHostKeyChecking=no $target 'whoami'",
          'Permission denied';
    };

    step 'Передача файла через scp и проверка подсистемы sftp' => sub {
        my $ssh_opts = "-i $key -o BatchMode=yes -o StrictHostKeyChecking=yes";
        run_cmd 'Creating a 1 MiB random file' => 'dd if=/dev/urandom of=/tmp/scp_src.bin bs=1M count=1';
        run_cmd 'Uploading the file to the server with scp' =>
          "scp $ssh_opts /tmp/scp_src.bin $target:/home/$test_user/scp_test.bin";
        run_cmd 'Downloading the file back with scp' =>
          "scp $ssh_opts $target:/home/$test_user/scp_test.bin /tmp/scp_back.bin";
        run_cmd 'Comparing the original and the downloaded file (cmp)' => 'cmp /tmp/scp_src.bin /tmp/scp_back.bin';
        run_cmd 'Running ls over sftp' => "printf 'ls\\n' | sftp -b - $ssh_opts $target";
        run_cmd 'Removing the test file on the server' => "ssh $ssh_opts $target 'rm -f scp_test.bin'";
    };

    step 'Отказ при использовании слабого шифра' => sub {
        expect_fail 'Trying to connect with the aes128-cbc cipher and expecting "no matching cipher found"' =>
          "ssh -i $key -o PasswordAuthentication=no -o Ciphers=aes128-cbc $target whoami",
          'no matching cipher';
    };

    barrier_wait 'client_checks_done';

    step 'Отказ при небезопасных правах ~/.ssh на сервере' => sub {
        barrier_wait 'perms_broken';

        # The barrier must be passed even if the check fails, otherwise the server waits forever
        my $ok = eval {
            expect_fail 'Key login must be refused while ~/.ssh on the server is world-writable' =>
              "ssh -i $key -o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=yes $target whoami",
              'Permission denied';
            1;
        };
        my $err = $@;
        barrier_wait 'client_perm_checked';
        barrier_wait 'perms_restored';
        die $err unless $ok;

        my $out = run_cmd 'After the permissions are restored, key login must work again' =>
          "ssh -i $key -o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=yes $target whoami";
        die "Expected '$test_user' in the output\n" unless $out =~ /^\Q$test_user\E$/m;
    };

    barrier_wait 'server_sshd_restarted';

    step 'Проверка сохранения работоспособности ключей после перезапуска sshd на сервере' => sub {
        my $ok = eval {
            run_cmd 'Logging in with the key after the sshd restart on the server' =>
              "ssh -i $key -o PasswordAuthentication=no -o StrictHostKeyChecking=yes $target 'echo SSH_OK' | grep -x SSH_OK";
            1;
        };
        my $err = $@;
        barrier_wait 'client_restart_checked';
        die $err unless $ok;
    };

    barrier_wait 'server_rebooted';

    step 'Проверка сохранения работоспособности ключей после перезагрузки сервера' => sub {
        my $ok = eval {
            run_cmd 'Logging in with the key after the server reboot' =>
              "ssh -i $key -o PasswordAuthentication=no -o StrictHostKeyChecking=yes $target 'echo SSH_OK_REBOOT' | grep -x SSH_OK_REBOOT";
            1;
        };
        my $err = $@;
        barrier_wait 'client_reboot_checked';
        die $err unless $ok;
    };

    step 'Проверка логов аудита и безопасности на клиенте' => sub {
        run_cmd 'Checking the journal for error/failed/fatal entries' =>
          q{! journalctl -u sshd --no-pager -n 100 | grep -iE 'error|failed|fatal'};
        run_cmd 'Checking for the absence of SELinux AVC denials since boot' =>
          q{! ausearch -m AVC,USER_AVC -ts boot | grep -q denied};
    };
}

sub post_fail_hook { write_step_report('openssh-client', failed => 1, qase_id => get_var('QASE_CASE_ID')) }
sub post_run_hook { write_step_report('openssh-client', qase_id => get_var('QASE_CASE_ID')) }

1;
