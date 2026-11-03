_pi_restech_setup_complete() {
  local -a candidates
  if (( CURRENT == 2 )); then
    candidates=(install remove uninstall update list config auth mcp --help --version --model --provider --thinking --extension --skill --theme --prompt-template --mode --print --continue --resume)
  elif [[ ${words[2]} == update && CURRENT == 3 ]]; then
    candidates=(self pi --self --extensions --models --all --extension --approve --no-approve --force)
  elif [[ ${words[2]} == update && ${words[CURRENT-1]} == --extension ]] || [[ ${words[2]} == (install|remove|uninstall) && CURRENT == 3 ]]; then
    candidates=(npm: @)
  elif [[ ${words[CURRENT]} == -* ]]; then
    candidates=(--help --version --model --provider --thinking --extension --no-extensions --skill --theme --prompt-template --mode --print --continue --resume)
  else
    _files
    return
  fi
  compadd -- "${(@)candidates}"
}

(( $+functions[compdef] )) || { autoload -Uz compinit; compinit; }
compdef _pi_restech_setup_complete pi
