use Mojo::Base 'basetest';

use testapi;

sub run {
    record_info(
        'Kickstart installation',
        'Starting automated AlmaLinux installation using Kickstart'
    );

    my $ks_path = 'kickstart/almalinux-minimal.ks';

    my $ks_content = get_test_data($ks_path);

    die "Kickstart file not found: $ks_path\n"
      unless defined $ks_content && length $ks_content;

    save_tmp_file($ks_path, $ks_content);

    my $ks_url = autoinst_url(
        "/files/$ks_path"
    );

    record_info(
        'Kickstart',
        "Using Kickstart file: $ks_url"
    );

    assert_screen('bootloader', 30);

    # Edit GRUB entry
    send_key('e');

    # Move from "setparams" to the "linux" line
    send_key('down');
    send_key('down');

    # Move cursor to the end of the linux command line
    hold_key('ctrl');
    send_key('e');
    release_key('ctrl');

    type_string(
        " inst.ks=$ks_url"
    );

    record_info(
        'Kickstart',
        'Booting installer with Kickstart configuration'
    );

    hold_key('ctrl');
    send_key('x');
    release_key('ctrl');

    record_info(
        'Kickstart',
        'Installation started in text mode'
    );
}

sub test_flags {
    return {fatal => 1};
}

1;
