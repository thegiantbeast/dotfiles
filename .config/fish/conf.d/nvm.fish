set -gx nvm_prefix (brew --prefix nvm)
set -gx NVM_DIR (brew --prefix nvm)

# Eager-load nvm default on shell startup so all global npm binaries are available
if status is-interactive
    nvm use default >/dev/null 2>&1
end
