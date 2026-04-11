@echo off
echo [objects] > temp.prj
echo temp.obj >> temp.prj

echo on
wla-65816 -o t7110.asm temp.obj
wlalink -vsr temp.prj t7110.bin
copy /b t7110_hdr.bin+t7110.bin SF2t7110
@echo off

del temp.obj
del temp.prj

