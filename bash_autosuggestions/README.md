### **Adding Autosuggestions to Bash with `ble.sh` on Fedora**

This guide explains how to install `ble.sh` to add fish-style autosuggestions and syntax highlighting to Bash shell.

#### **Step 1: Install Prerequisites**

The recommended installation method requires `git`, `make`, and `gawk`. Run the following command to ensure they are all installed on your system.

```bash
sudo dnf install git make gawk
```

#### **Step 2: Download and Install `ble.sh`**

These commands will download the source code, run the installer to place the final script in the correct directory (`~/.local/share/blesh`), and then clean up.

```bash
# Go to your home directory for a clean start
cd ~

# 1. Download the source code from GitHub
git clone --recursive --depth 1 --shallow-submodules https://github.com/akinomyoga/ble.sh.git

# 2. Build and install the script
make -C ble.sh install PREFIX=~/.local

# 3. (Optional) Clean up the downloaded source code directory
rm -rf ~/ble.sh
```

#### **Step 3: Configure Your `.bashrc`**

We need to tell Bash to load `ble.sh` every time it starts. This command will append the required line to the end of bash configuration file.

**Important:** This line should be at the **very end** of your `~/.bashrc`

```bash
echo 'source -- ~/.local/share/blesh/ble.sh' >> ~/.bashrc
```

#### **Step 4: Activate and Use**

1.  **Reload shell:** Close and reopen your terminal, or run the command `source ~/.bashrc`.

2.  **First-Time Cache:** Afer installig and relaunching a new terminal, will show a message like `ble/term.sh: updating tput cache...`. This is a normal, one-time setup process. It will not appear on subsequent launches.

3.  **Start Typing:** Suggestions will appear in faint grey text.

      * To **accept the suggestion**, press the **Right Arrow key (`→`)** or the **End** key.
      * To **ignore it**, just keep typing.
