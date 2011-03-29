#!/bin/bash
# Generate a rakerunner release
# Assumes that you have checked out the entire RakeRunner project from 
# http://svn.miningbased.com/svn/rakerunner and that you are calling this
# script from it's base. 
# 
# For example
# svn co http://svn.miningbased.com/svn/rakerunner 
# cd ./rakerunner/
#
# Dependecies
#
# To build gems you must install the 'builder' gem
# gem install builder

                                                      
# Release type is development unless called with --production
SRC_DIR=./trunk
REL_DIR=./dev-releases
REL_TYPE=development
for opt in $@; do
  if [[ $opt == '--production' ]]; then
    REL_DIR=./releases
    REL_TYPE=production
  fi
done

# Check that there are no modifications in trunk or releases
if [ `svn status $SRC_DIR |grep -E "^M|D|A|!" -c` != 0 ]; then
  echo "Changes (moves, add, deteles, or missings) found in $SRC_DIR"
  echo "Commit or revert changes to trunk before continuing."
  exit 1
fi

if [ `svn status $REL_DIR |grep -E "^M|D|A|!" -c` != 0 ]; then
  echo "Changes (moves, add, deteles, or missings) found in $REL_DIR"
  echo "Commit or revert changes to releases before continuing."
  exit 1
fi

# Get the revision number and name of the gem
REV=`svn info $SRC_DIR |grep Revision |cut -c11-`
RELNAME=rakerunner-$REV
GEMNAME=$RELNAME.gem

# Check that a gem with this version number does not already exist
if [[ -e ./releases/gems/$GEMNAME || -e ./dev-releases/gems/$GEMNAME ]]; then
  echo "gem $RELNAME alread exists. Try running svn up to update the revision number. Quitting."
  exit 1
fi

# Check the revision number
if [ $REV != `svn info $REL_DIR |grep Revision |cut -c11-` ];then
  echo "$SRC_DIR and $REL_DIR svn revision numbers do not match."
  echo "Try running 'svn up' to before continuing."
  exit 1
fi

# Notify user of release type and require confirmation
echo "This script will generate a $REL_TYPE release of $GEMNAME"
if [[ $REL_TYPE != 'production' ]]; then
  echo "You can create an production release by passing --production."
fi
echo -e "Are you sure you want to continue? [y/N] \c "
read ANSWER
echo

if [[ $ANSWER != 'y' && $ANSWER != 'Y' ]];then
  echo Installer quitting.
  exit 0
fi

#-----------------------------------------------------------------------------
# Build the gem and create the release
#-----------------------------------------------------------------------------
# Fly the flag
cat <<EOF
 "Building $GEMNAME release of "
     __       _          __                              
    /__\ __ _| | _____  /__\_   _ _ __  _ __   ___ _ __  
   / \/// _\` | |/ / _ \/ \// | | | '_ \| '_ \ / _ \ '__| 
  / _  \ (_| |   <  __/ _  \ |_| | | | | | | |  __/ |    
  \/ \_/\__,_|_|\_\___\/ \_/\__,_|_| |_|_| |_|\___|_|   

EOF

#Build the gem 
cd $SRC_DIR
gem build rakerunner.gemspec
if [[ $? != 0 ]]; then
  echo 'There was an error creating the gem. Quitting.'
  exit $?
fi
cd ..

#Move gem to $REL_DIR gems and svn add it
mv $SRC_DIR/$GEMNAME $REL_DIR/gems/
svn add $REL_DIR/gems/$GEMNAME

#Regenerate the gem index and add the changes
cd $REL_DIR
cp -r quick quick_cp #generate_index clobbers .svn dirs
gem generate_index -d .
if [[ $? != 0 ]]; then
  echo -e "There was an error generating the gem index.\nTry running gem install builder. Quitting."
  exit $?
fi
mv quick_cp/.svn quick/.svn
mv quick_cp/Marshal.4.8/.svn quick/Marshal.4.8/.svn
rm -Rf quick_cp
#These two adds some times raise svn warnings if rerelesing but are needed
svn add quick/$RELNAME.gemspec.rz 
svn add quick/Marshal.4.8/$RELNAME.gemspec.rz
cd ..

echo "A $REL_TYPE release has been created but not committed to svn."
echo -e "Do you want to commit now? [y/N] \c "
read ANSWER
echo 

if [[ $ANSWER != 'y' && $ANSWER != 'Y' ]];then
  echo "You must run 'svn commit' to complete your release."
  echo "Happy running."
  exit 0
else
  svn ci $REL_DIR -m "$new dev release: $GEMNAME"
  echo "Your release has been committed. Happy running."
fi
