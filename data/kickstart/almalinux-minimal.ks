#version=RHEL10

# Switching Anaconda to text mode
text

# Automatic reboot after installation is complete
reboot

# Принятие лицензии и отключение первого мастера настройки
eula --agreed
firstboot --disable

%addon com_redhat_kdump --enable --reserve-mb='auto'

%end

# Keyboard layouts
keyboard --vckeymap=us --xlayouts='us' --switch='grp:alt_shift_toggle'
# System language
lang en_US.UTF-8

%packages
@^minimal-environment

%end

# Generated using Blivet version 3.13.0
ignoredisk --only-use=vda
autopart
# Partition clearing information
clearpart --none --initlabel

# System timezone
timezone Europe/Moscow --utc

# Root password
rootpw --iscrypted --allow-ssh $y$j9T$0SXdUhYRVAbfG/EG3udOyo.d$u4WI5/Lg9EAGlzocNDDR2Ahf4U6ARRZ3uRPd6nrt5L9