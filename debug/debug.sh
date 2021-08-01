#!/bin/bash

pacman -S git ruby glibc libxcrypt --noconfirm
git clone https://github.com/marlospomin/warding
cd warding
pacman -R man-pages --noconfirm
gem install bundle rake
export PATH="`ruby -e 'puts Gem.user_dir'`/bin:$PATH"
bundle
rake install
warding
