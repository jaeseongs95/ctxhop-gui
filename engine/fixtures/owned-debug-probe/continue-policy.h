#ifndef CTXHOP_CONTINUE_POLICY_H
#define CTXHOP_CONTINUE_POLICY_H

/* Accepted termination requests permit Continue; they do not prove exit. */
static int can_continue_create(unsigned slot, int validated, int currentMember,
                               int jobTerminationAccepted, int exactTerminationAccepted)
{
    return exactTerminationAccepted || (slot < 2 && currentMember
        && (validated || jobTerminationAccepted));
}

#endif
