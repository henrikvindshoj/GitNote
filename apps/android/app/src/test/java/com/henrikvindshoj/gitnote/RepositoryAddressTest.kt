package com.henrikvindshoj.gitnote

import com.henrikvindshoj.gitnote.domain.RepositoryAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RepositoryAddressTest {
    @Test
    fun parsesSlugAndGitHubUrl() {
        assertEquals(
            RepositoryAddress("henrikvindshoj", "GitNote-Test-Repo"),
            RepositoryAddress.parse("henrikvindshoj/GitNote-Test-Repo"),
        )
        assertEquals(
            RepositoryAddress("henrikvindshoj", "GitNote"),
            RepositoryAddress.parse("https://github.com/henrikvindshoj/GitNote.git"),
        )
    }

    @Test
    fun rejectsUnsupportedAndTraversalAddresses() {
        assertNull(RepositoryAddress.parse("https://example.com/owner/repo"))
        assertNull(RepositoryAddress.parse("owner/../repo"))
        assertNull(RepositoryAddress.parse("owner/repo/extra"))
        assertNull(RepositoryAddress.parse(""))
    }
}
