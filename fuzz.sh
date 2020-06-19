#!/bin/bash
#
# set -x

# fuzz testing of Tor software as mentioned in
# https://gitweb.torproject.org/tor.git/tree/doc/HACKING/Fuzzing.md


# preparation steps at Gentoo Linux:
#
# (I) install AFL++
#
# emerge --update sys-devel/clang app-forensics/AFLplusplus
#
# (II) clone Git repositories
#
# cd ~
# git clone https://github.com/jwilk/recidivm
# git clone https://git.torproject.org/fuzzing-corpora.git
# git clone https://git.torproject.org/tor.git
#
# (III) build fuzzers:
#
# fuzz.sh -u
#
# (IV) get/check memory limit (add 50M at the highest value as suggested by recidivm upstream)
#
# cd ~/tor; for i in $(ls ./src/test/fuzz/fuzz-* 2>/dev/null); do echo $(../recidivm/recidivm -v -u M $i 2>&1 | tail -n 1) $i ; done | sort -n
#
# (V) start an arbitrary fuzzer:
#
# fuzz.sh -s 1


function Help() {
  echo
  echo "  call: $(basename $0) [-h|-?] [-acflru] [-s '<fuzzer name(s)>'|<fuzzer amount>]"
  echo
}



function __listWorkDirs() {
  ls -1d $workdir/*_*_20??????-?????? 2>/dev/null
}


function __getPid() {
  grep "fuzzer_pid" $1/fuzzer_stats 2>/dev/null | awk ' { print $3 } '
}


# 0 = it is runnning
# 1 = it is stopped
function __isRunning()  {
  pid=$(__getPid $1)
  if [[ -n "$pid" ]]; then
    kill -0 $pid 2>/dev/null
    return $?
  fi

  return 1
}


# archive findings
#
function archiveOrRemove()  {
  for d in $(__listWorkDirs)
  do
    __isRunning $d && continue
    echo
    if [[ -n "$(ls $d/*.tbz2 2>/dev/null)" ]]; then
      echo " $d HAS findings, keep it in ~/archive/$d"
      if [[ ! -d ~/archive ]]; then
        mkdir ~/archive || return 1
      fi
      mv $d $homedir/archive
    else
      echo
      logfile=$d/fuzz.log
      grep -B 100 "We're done here. Have a nice day" $logfile
      if [[ $? -eq 0 ]]; then
        echo " $d has no findings, will remove it"
        rm -rf $d
      else
        echo " $d abnormal breakage ?!"
        tail -v -n 20 $logfile
      fi
    fi
    echo
  done
}


# check for findings
#
function checkForFindings()  {
  for d in $(__listWorkDirs)
  do
    for i in crashes hangs
    do
      if [[ -z "$(ls $d/$i 2>/dev/null)" ]]; then
        continue
      fi

      tbz2=$(basename $d)-$i.tbz2

      # already reported ?
      #
      if [[ -f $d/$tbz2 && $tbz2 -ot $d/$i ]]; then
        continue
      fi

      (
        echo "verify $i it with 'cd $d; ./fuzz-* < ./$i/*' then inform tor-security@lists.torproject.org"
        echo
        cd $d                             &&\
        tar -cjpf $tbz2 ./$i 2>&1         &&\
        uuencode $tbz2 $(basename $tbz2)
      ) | mail -s "$(basename $0) $i in $d" $mailto -a ""
    done
  done
}


function gnuplot()  {
  for d in $(__listWorkDirs)
  do
    (cd $d && afl-plot . .)
  done
}


# check log files for anomalies
#
function LogCheck() {
  for d in $(__listWorkDirs)
  do
    log=$d/fuzz.log
    diff=$(( $(date +%s) - $(stat -c%Y $log) ))

    grep -h -B 20 -A 10 'PROGRAM ABORT :' $log
    rc=$?

    if [[ $diff -gt 3600 || $rc -eq 0 ]]; then
      echo
      echo " last logfile access $diff sec ago:"
      echo
      stat $log
    fi
  done
}


# spin up the given fuzzer
#
function startIt()  {
  fuzzer=${1?:fuzzer ?!}
  idir=${2?:idir ?!}
  odir=${3?:odir ?!}

  # optional: dictionary for the fuzzer
  #
  dict="$TOR/src/test/fuzz/dict/$fuzzer"
  if [[ -e $dict ]]; then
    dict="-x $dict"
  else
    dict=""
  fi

  exe=$workdir/$odir/fuzz-$fuzzer
  if [[ ! -x $exe ]]; then
    echo "no exe found for $fuzzer"
    return 1
  fi

  nohup nice -n 1 /usr/bin/afl-fuzz -i $idir -o $workdir/$odir -m 9000 $dict -- $exe &>>$workdir/$odir/fuzz.log &
  pid=$(__getPid $odir)

  if [[ $cgroup = "yes" ]]; then
    sudo $homedir/fuzz_helper.sh $odir $pid || return $?
  fi

  echo
  echo " started $fuzzer pid=$pid odir=$workdir/$odir"
  echo
}


# resume fuzzer(s)
function ResumeFuzzers()  {
  for d in $(ls -1d $workdir/*_*_20??????-?????? 2>/dev/null)
  do
    __isRunning $d && continue
    fuzzer=$(basename $d | cut -f1 -d'_')
    idir="-"
    odir=$d
    startIt $fuzzer $idir $odir || break
  done
}


# spin up new fuzzer(s)
#
function startFuzzer()  {
  fuzzer=$1

  # input data file for the fuzzer
  #
  idir=$TOR_FUZZ_CORPORA/$fuzzer
  if [[ ! -d $idir ]]; then
    echo " idir not found: $idir"
    return 1
  fi

  # output directory: timestamp + git commit id + fuzzer name
  #
  cid=$(cd $TOR; git describe 2>/dev/null | sed 's/.*\-g//g')
  odir=${fuzzer}_${cid}_$(date +%Y%m%d-%H%M%S)
  mkdir -p $workdir/$odir || return 2

  # run a copy of the fuzzer b/c git repo is subject of change
  #
  cp $TOR/src/test/fuzz/fuzz-$fuzzer $workdir/$odir

  startIt $fuzzer $idir $odir
}


# update Tor fuzzer software stack
#
function updateSources() {
  echo " update deps ..."

  cd $RECIDIVM
  git pull
  make || return 1

  cd $TOR_FUZZ_CORPORA
  git pull

  cd $TOR
  git pull

  echo " run recidivm to check anything much bigger than 50 which indicates a broken (linker) state"
  m=$(for i in $(ls ./src/test/fuzz/fuzz-* 2>/dev/null); do echo $(../recidivm/recidivm -v -u M $i 2>/dev/null | tail -n 1); done | sort -n | tail -n 1)
  if [[ -n "$m" ]]; then
    if [[ $m -gt 200 ]]; then
      echo " force distclean (recidivm gave M=$m) ..."
      make distclean 2>&1
    fi
  fi

  if [[ ! -x ./configure ]]; then
    rm -f Makefile
    echo " autogen ..."
    ./autogen.sh 2>&1 || return 2
  fi

  if [[ ! -f Makefile ]]; then
    # use the configre options from the official Gentoo ebuild, but :
    #   - disable coverage, this has a huge slowdown effect
    #   - enable zstd-advanced-apis
    echo " configure ..."
    gentoo_options="
        --prefix=/usr --build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu --mandir=/usr/share/man --infodir=/usr/share/info --datadir=/usr/share --sysconfdir=/etc --localstatedir=/var/lib --disable-dependency-tracking --disable-silent-rules --docdir=/usr/share/doc/tor-0.4.3.5 --htmldir=/usr/share/doc/tor-0.4.3.5/html --libdir=/usr/lib64 --localstatedir=/var --enable-system-torrc --disable-android --disable-html-manual --disable-libfuzzer --enable-missing-doc-warnings --disable-module-dirauth --enable-pic --disable-rust --disable-restart-debugging --disable-zstd-advanced-apis --enable-asciidoc --enable-manpage --enable-lzma --enable-libscrypt --enable-seccomp --enable-module-relay --disable-systemd --enable-gcc-hardening --enable-linker-hardening --disable-unittests --disable-coverage --enable-zstd
    "
    override="
        --enable-module-dirauth --enable-zstd-advanced-apis --enable-unittests --disable-coverage
    "
    ./configure $gentoo_options $override || return 3
  fi

  # https://trac.torproject.org/projects/tor/ticket/29520
  #
  echo " make ..."
  make micro-revision.i 2>&1  || return 4
  make -j 9 fuzzers 2>&1      || return 5
}


#######################################################################
#
# main
#
mailto="torproject@zwiebeltoralf.de"

if [[ $# -eq 0 ]]; then
  Help
fi

# simple lock to avoid being run in parallel
#
lck=~/.lock
if [[ -s $lck ]]; then
  echo -n " found $lck,"
  ls -l $lck
  tail -v $lck
  kill -0 $(cat $lck) 2>/dev/null
  if [[ $? -eq 0 ]]; then
    echo " valid, exiting ..."
    exit 1
  else
    echo " stalled, continuing ..."
  fi
fi
echo $$ > $lck

cd $(dirname $0)
homedir=$(pwd)

# sources
export RECIDIVM=~/recidivm
export TOR_FUZZ_CORPORA=~/tor-fuzz-corpora
export TOR=~/tor

# common
export CFLAGS="-O2 -pipe -march=native"

# afl-fuzz
export AFL_HARDEN=1

export AFL_SHUFFLE_QUEUE=1
export AFL_EXIT_WHEN_DONE=1

# export AFL_NO_FORKSRV=1
export AFL_SKIP_CPUFREQ=1

# llvm_mode
export CC="/usr/bin/afl-clang-fast"
export AFL_LLVM_INSTRUMENT=CFG

# /tmp is a tmpfs, this avoids any I/O at disc
workdir=/tmp/AFLplusplus/
if [[ ! -d $workdir ]]; then
  mkdir -p $workdir || exit 1
fi

cgroup="no"

while getopts acfghlrs:u\? opt
do
  case $opt in
    a)  archiveOrRemove || break
        ;;
    c)  cgroup="yes"
        ;;
    f)  checkForFindings || break
        ;;
    g)  gnuplot
        ;;
    h|\?)Help
        ;;
    l)  LogCheck || break
        ;;
    r)  ResumeFuzzers || break
        ;;
    s)
        test -z "${OPTARG//[0-9]}"
        if [[ $? -eq 0 ]]; then
          # integer given
          all=""
          for fuzzer in $(ls $TOR_FUZZ_CORPORA 2>/dev/null)
          do
            [[ -x $TOR/src/test/fuzz/fuzz-$fuzzer ]] && all="$all $fuzzer"
          done
          fuzzers=$(echo $all | xargs -n 1 | shuf -n $OPTARG)
        else
          # fuzzer name(s) given
          fuzzers="$OPTARG"
        fi

        for fuzzer in $fuzzers
        do
          startFuzzer $fuzzer || break 2
        done
        ;;
    u)  updateSources || break
        ;;
  esac
done

rm $lck
