@echo off
echo [objects] > temp.prj
echo temp.obj >> temp.prj

echo on
wla-65816 -o t7110.asm temp.obj
wlalink -vsr temp.prj t7110.sfc
@echo off

del temp.obj
del temp.prj

