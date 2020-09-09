#!/bin/bash

pacman -R man-pages --noconfirm
pacman -Syy ruby glibc libxcrypt --noconfirm
gem install warding
