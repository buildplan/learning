### Install and Setup Starship on Fedora

This guide covers the four essential steps: installing the program, setting up the necessary fonts, integrating it with your shell, and customizing the look.

#### **Step 1: Install Starship**

The most reliable method is using the official installer script, which always fetches the latest version.

```bash
curl -sS https://starship.rs/install.sh | sh
```

#### **Step 2: Install and Set a Nerd Font**

For all the cool icons (like Git branches, folder icons, etc.) to display correctly, you need a special font.

1.  **Install the font:** A great option on Fedora is FiraCode Nerd Font.

    ```bash
    sudo dnf install fira-code-fonts
    ```

2.  **Set the font:** Open your terminal application's **Preferences** (or Settings/Profiles). Find the font setting and change it to **`FiraCode Nerd Font`**. You must do this for the icons to appear.

#### **Step 3: Make Starship Start Automatically**

This is the crucial step to make your shell use Starship every time it starts.

1.  **Find your shell:**

    ```bash
    echo $SHELL
    ```

2.  **Run the command for your shell** (e.g., if the output was `/bin/bash`, use the Bash command):

      * **For Bash:**

        ```bash
        echo 'eval "$(starship init bash)"' >> ~/.bashrc
        ```

      * **For Zsh:**

        ```bash
        echo 'eval "$(starship init zsh)"' >> ~/.zshrc
        ```

      * **For Fish:**

        ```bash
        echo 'starship init fish | source' >> ~/.config/fish/config.fish
        ```

#### **Step 4: Customize Your Prompt (Optional but Recommended)**

Create a configuration file to make the prompt look exactly how you want.

1.  **Create the config file:**

    ```bash
    mkdir -p ~/.config && touch ~/.config/starship.toml
    ```

2.  **Edit the file** (`~/.config/starship.toml`) and add your settings. Here is a great starter template you can paste in:

    ```toml
    # ~/.config/starship.toml

    # A clean, two-line prompt.
    format = """
    $directory\
    $git_branch\
    $git_status\
    $line_break\
    $character"""

    # Don't print a new line before the prompt
    add_newline = false

    [directory]
    style = "bold cyan"
    truncation_length = 4 # Show only the last 4 directories in the path

    [git_branch]
    symbol = "🌱 "
    style = "bold green"

    [git_status]
    style = "bold red"
    stashed = "📦"
    ahead = "⇡"
    behind = "⇣"
    diverged = "🤷"

    # The character at the very end of the prompt
    [character]
    success_symbol = "[➜](bold green)"
    error_symbol = "[✗](bold red)"
    ```

3.  **For all customization options**, refer to the official [Starship Configuration Documentation](https://starship.rs/config/).

Finally, **close and reopen your terminal** to see all your changes take effect. Your beautiful, custom prompt will now be there every time.
