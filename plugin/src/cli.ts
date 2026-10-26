#!/usr/bin/env node
/**
 * `dsh-duo pair`    show the pairing QR and link
 * `dsh-duo rotate`  replace the pairing secret (unpairs every phone)
 * `dsh-duo status`  show the relay and pairing file
 */

import { readFile } from 'node:fs/promises'
import { hostname } from 'node:os'
import { dshHome, pairingLink, pairingPath, pairingQr, rotatePairing, type Pairing } from './pairing.ts'

const [command = 'pair'] = process.argv.slice(2)
const path = pairingPath(dshHome())

async function read(): Promise<Pairing> {
  try {
    return JSON.parse(await readFile(path, 'utf8')) as Pairing
  } catch {
    console.error(`No pairing at ${path}. Start dsh once with the duo-remote plugin installed.`)
    process.exit(1)
  }
}

switch (command) {
  case 'pair': {
    const pairing = await read()
    const link = pairingLink(pairing, hostname())
    console.log(await pairingQr(link))
    console.log('Scan with DSH Duo on your iPhone, or open this link on the phone:')
    console.log(link)
    break
  }
  case 'rotate': {
    const current = await read()
    const pairing = await rotatePairing(path, current.relay)
    console.log('Pairing rotated. Restart dsh, then scan:')
    console.log(await pairingQr(pairingLink(pairing, hostname())))
    break
  }
  case 'status': {
    const pairing = await read()
    console.log(`relay  ${pairing.relay}\nroom   ${pairing.roomId}\npaired ${pairing.paired === true ? 'yes' : 'no'}\nfile   ${path}`)
    break
  }
  default:
    console.log('usage: dsh-duo [pair|rotate|status]')
    process.exit(2)
}
