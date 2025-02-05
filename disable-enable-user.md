Disable a User Account Using usermod: The usermod command is a powerful tool used to modify user accounts in Linux. To disable an account, the -L (lock) option can be used.

# usermod -L username

This command locks the specified user account by disabling their password. The user will not be able to log in until the account is unlocked using the -U option:

# usermod -U username

Unlocking the account restores the user’s ability to log in.
