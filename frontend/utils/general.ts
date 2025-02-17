import { TxHash } from "./types/TxHash";
import { BigNumber, BigNumberish, utils } from "ethers";

export const truncateAddress = (address: string): string =>
  `${address.slice(0, 4)}...${address.slice(-4)}`;

export const convertBigNumber = (data: TxHash): string => {
  return data.toString();
};

export const canStake = (
  allowance: BigNumberish,
  balanceOf: BigNumberish,
  minimumStake: BigNumberish,
  initiateAddress: string,
  willSponsor: boolean
): boolean => {
  const _minimumStake = Number(utils.formatEther(minimumStake));
  const _allowance = Number(utils.formatEther(allowance));
  const _balanceOf = Number(utils.formatEther(balanceOf));

  let canStakeLogic =
    _allowance >= _minimumStake &&
    _balanceOf >= _minimumStake;

  let willSponsorlogic = willSponsor
    ? canStakeLogic
    : canStakeLogic && utils.isAddress(initiateAddress);
  if (willSponsor) return willSponsorlogic;
  else return canStakeLogic;
};

export const stakeTooltip = (
  allowance: BigNumberish,
  balanceOf: BigNumberish,
  minimumStake: BigNumberish,
  initiateAddress: string,
  willSponsor: boolean
): string | null => {
  let label: string = "";

  const _minimumStake = Number(utils.formatEther(minimumStake));
  const _allowance = Number(utils.formatEther(allowance));
  const _balanceOf = Number(utils.formatEther(balanceOf));

  if (willSponsor) {
    if (!utils.isAddress(initiateAddress)) {
      label = "Please input a valid wallet address";
    } else if (_allowance < _minimumStake) {
      label =
        "You must approve the contract to spend your balance before you can stake";
    } else if (_balanceOf < _minimumStake) {
      label = "Your balance is too low";
    }
  } else if (!willSponsor) {
    if (_balanceOf < _minimumStake) {
      label = "Your balance is too low";
    } else if (_allowance < _minimumStake) {
      label =
        "Allowance is smaller than the minimum stake amount. Please approve allowance.";
    }
  } else return null;
  return label;
};

export const approveTooltip = (
  allowance: BigNumberish,
  balanceOf: BigNumberish,
  minimumStake: BigNumberish,
  tokenSymbol: string
): string | null => {
  let label: string = "";

  const _minimumStake = Number(utils.formatEther(minimumStake));
  const _allowance = Number(utils.formatEther(allowance));
  const _balanceOf = Number(utils.formatEther(balanceOf));

  if (_balanceOf < _minimumStake) {
    label = "Your balance is too low";
  } else if (_allowance < _minimumStake) {
    label = `Approve contract to spend your ${tokenSymbol}`;
  } else {
    return null;
  }
  return label;
};

/**
 *
 * @param createdAt
 * @param time
 * @returns unix strring
 */
export const getDeadline = (
  createdAt: string,
  time: string
): number => {
  let deadline = (Number(createdAt) * 1000 + Number(time) * 1000);
  return deadline;
};

export const unixToUTC = (unix: string): string => {
  const utc = new Date(Number(unix));
  const localDate = utc.toLocaleDateString();
  return localDate;
};

export const getHasRite = (riteBalance: BigNumber | null): boolean => {
  let rites = Number(riteBalance?.toString());
  if (rites > 0) {
    return true;
  } else if (rites === 0 || !rites) {
    return false;
  }
  return false;
};

export const numberDecimals = (variable: string, decimals: number) =>
  Number(variable).toFixed(decimals);
