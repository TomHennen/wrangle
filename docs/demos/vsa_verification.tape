# vsa_verification.tape — downstream VSA verification with ampel (jsonl collector).
# Render from this directory:  cd docs/demos && vhs vsa_verification.tape  (see README.md)
# The command, policy, collector, and checks mirror build/actions/*/README.md;
# the output is produced by vsa_verify_demo.sh (shimmed in as `ampel`).
Output ../../assets/images/vsa_verification.gif

Set Shell bash
Set Theme "Catppuccin Mocha"
Set Width 1200
Set Height 600
Set Padding 20
Set FontSize 16
Set TypingSpeed 30ms

Hide
Type `export PS1='$ '`
Enter
Type `export PS2='> '`
Enter
Type `mkdir -p /tmp/vsa-demo && ln -sf "$PWD/vsa_verify_demo.sh" /tmp/vsa-demo/ampel`
Enter
Type `export PATH="/tmp/vsa-demo:$PATH"`
Enter
Type `clear`
Enter
Show

Sleep 800ms
Type `ampel verify --subject hello-world_1.2.0_linux_amd64.tar.gz \`
Enter
Type `  --policy git+https://github.com/TomHennen/wrangle@v0.2.2#policies/wrangle-vsa-consumer-v1.hjson \`
Enter
Type `  --collector jsonl:hello-world_1.2.0_linux_amd64.tar.gz.intoto.jsonl \`
Enter
Type `  --context expectedResourceUri:pkg:golang/github.com/acme/hello-world@v1.2.0 \`
Enter
Type `  --context sourceRepo:https://github.com/acme/hello-world`
Sleep 1.2s
Enter

Sleep 11s
