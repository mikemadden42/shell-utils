#!/bin/bash

# Array of extensions to install
extensions=(
	charliermarsh.ruff
	davidanson.vscode-markdownlint
	dimitarnonov.jellybeans-theme
	esbenp.prettier-vscode
	frhtylcn.pythonsnippets
	golang.go
	jdinhlife.gruvbox
	ms-python.python
	ms-vscode.theme-tomorrowkit
	nimsaem.nimvscode
	redhat.vscode-xml
	redhat.vscode-yaml
	rust-lang.rust-analyzer
	ryanolsonx.zenburn
	tamasfe.even-better-toml
	vscodevim.vim
	wholroyd.jinja
)

echo "Starting VS Code extension installation..."

# Loop through the array and install each extension
for extension in "${extensions[@]}"; do
	echo "Installing: $extension"
	code --install-extension "$extension" --force
done

echo "All extensions have been processed!"
