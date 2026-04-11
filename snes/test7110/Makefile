PREFIX    =
AS        = $(PREFIX)wla-65816
LD        = $(PREFIX)wlalink
SOURCES     = \
  t7110.asm

OUTPUT    = t7110.sfc
SFLAGS    = -x -o
LDFLAGS   = -v -d -s Linkfile
SRCS      = $(SOURCES)

.PHONY: all clean

all: clean t7110.o Linkfile $(OUTPUT)

t7110.o: $(SRCS)
	$(AS) $(SFLAGS) $@ $<
$(OUTPUT): t7110.o
	$(LD) $(LDFLAGS) $@
Linkfile:
	echo [objects]>Linkfile
	echo t7110.o>>Linkfile
clean:
	$(RM) $(OUTPUT) *.o *.sym Linkfile
