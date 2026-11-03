_pi_restech_setup_complete() {
  local cur prev words cword
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  words=("${COMP_WORDS[@]}")
  cword=$COMP_CWORD

  if (( cword == 1 )); then
    COMPREPLY=( $(compgen -W 'install remove uninstall update list config auth mcp --help --version --model --provider --thinking --extension --skill --theme --prompt-template --mode --print --continue --resume' -- "$cur") )
    return
  fi

  if [[ ${words[1]} == update ]]; then
    if (( cword == 2 )); then
      COMPREPLY=( $(compgen -W 'self pi --self --extensions --models --all --extension --approve --no-approve --force' -- "$cur") )
      return
    fi
    if [[ ${prev} == --extension ]]; then
      COMPREPLY=( $(compgen -W 'npm: @' -- "$cur") )
      return
    fi
  fi

  if [[ ${words[1]} == install || ${words[1]} == remove || ${words[1]} == uninstall ]]; then
    if (( cword == 2 )); then
      COMPREPLY=( $(compgen -W 'npm: @' -- "$cur") )
      return
    fi
  fi

  if [[ $cur == -* ]]; then
    COMPREPLY=( $(compgen -W '--help --version --model --provider --thinking --extension --no-extensions --skill --theme --prompt-template --mode --print --continue --resume' -- "$cur") )
  else
    COMPREPLY=( $(compgen -f -- "$cur") )
  fi
}

complete -F _pi_restech_setup_complete pi
